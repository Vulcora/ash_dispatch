defmodule AshDispatch.Dispatcher do
  @moduledoc """
  Core dispatcher that handles event delivery across all transports.

  This module orchestrates the dispatch process:
  1. Creates DeliveryReceipt with full content
  2. Routes to appropriate transport handler
  3. Updates receipt status based on delivery result

  ## Receipt-First Pattern

  All deliveries follow the receipt-first pattern:
  - Receipt created BEFORE delivery attempt
  - Full content stored in receipt (enables retries without re-rendering)
  - Status tracked through lifecycle: pending → scheduled/sent → failed

  ## Transport Routing

  - `:in_app` → `AshDispatch.Transports.InApp` (synchronous)
  - `:email` → `AshDispatch.Transports.Email` (async via Oban)
  - `:discord` → `AshDispatch.Transports.Discord` (async via Oban)
  - `:slack` → `AshDispatch.Transports.Slack` (async via Oban)
  - `:sms` → `AshDispatch.Transports.SMS` (async via Oban)
  - `:webhook` → `AshDispatch.Transports.Webhook` (async via Oban)
  """

  alias AshDispatch.Config
  alias AshDispatch.Context
  alias AshDispatch.ChannelResolver
  alias AshDispatch.EventResolver
  alias AshDispatch.Naming
  alias AshDispatch.Transports
  alias AshDispatch.Event.RecipientExtractor
  alias AshDispatch.Helpers.RecordReader

  require Logger

  @doc """
  Dispatches an event by ID with data and variables.

  This is the high-level dispatch function that applications use.
  It looks up the event module, creates channels, and dispatches to all of them.

  ## Parameters

  - `event_id` - The event identifier (e.g., "requests.new_reseller_request")
  - `data` - Map of domain data (resources, users, etc.)
  - `variables` - Map of template variables (tokens, simple values, etc.) - defaults to %{}

  ## Returns

  - `{:ok, results}` - List of delivery receipt results
  - `{:error, reason}` - If event not found or dispatch fails

  ## Data vs Variables

  Use `data` for:
  - Domain resources (User, Order, Ticket, etc.)
  - Structured Ash resources
  - Objects that need relationship traversal

  Use `variables` for:
  - Authentication tokens (reset_token, confirmation_token)
  - Simple template values
  - Computed values that don't need relationships

  This separation prevents naming conflicts and makes the intent clearer.

  ## Examples

      # Dispatch with authentication token
      AshDispatch.Dispatcher.dispatch(
        "accounts.password_reset",
        %{user: user},
        %{reset_token: token}
      )

      # Dispatch with invitation data
      AshDispatch.Dispatcher.dispatch(
        "accounts.invited",
        %{invited_user: user, invited_by: admin},
        %{invitation_token: token, custom_message: message}
      )

      # Dispatch an order created event (no variables needed)
      AshDispatch.Dispatcher.dispatch(
        "orders.created",
        %{order: order, user: user}
      )
  """
  # Function head with default parameter
  def dispatch(event_id, data, variables \\ %{})

  def dispatch(event_id, data, variables)
      when is_binary(event_id) and is_map(data) and is_map(variables) do
    # Use centralized EventResolver for consistent event lookup
    case EventResolver.find_module(event_id) do
      {:ok, event_module} ->
        # Create initial context (before generate_send_variables)
        initial_context = %Context{
          event_id: event_id,
          data: data,
          variables: variables,
          user: extract_user_from_data(data)
        }

        # Generate real variables using EventResolver (handles function_exported? and error handling)
        # This allows events to provide real data (tokens, etc.) for actual sending
        # while using sample_data() for previews
        enhanced_vars_result =
          EventResolver.generate_send_variables(event_module, initial_context, variables)

        case enhanced_vars_result do
          {:ok, enhanced_variables} ->
            # Update context with enhanced variables
            context = %{initial_context | variables: enhanced_variables}

            # Use centralized ChannelResolver for consistent priority logic
            channels = ChannelResolver.resolve(event_id, event_module, context)

            # Build event config
            event_config = %{
              module: event_module
            }

            # Dispatch to all channels
            # Deduplication is opt-in via deduplicate_in_app: true in event config
            results = dispatch_all_channels(channels, context, event_config)

            # Return success if any dispatch succeeded
            if Enum.any?(results, fn
                 {:ok, _} -> true
                 _ -> false
               end) do
              {:ok, results}
            else
              {:error, :all_dispatches_failed}
            end

          {:error, reason} ->
            Logger.error("generate_send_variables failed for #{event_id}: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, :not_found} ->
        Logger.error("Event module not found for event_id: #{event_id}")
        {:error, :event_not_found}
    end
  end

  @doc """
  Low-level dispatch function that dispatches to a specific channel with a pre-built context.

  This is used internally and by DSL-based events that build their own context.
  Most applications should use the high-level `dispatch/2` or `dispatch/3` functions instead.

  ## Parameters

  - `context` - Pre-built AshDispatch.Context struct
  - `channel` - AshDispatch.Channel struct
  - `event_config` - Event configuration map (with :module, :content, etc.)

  ## Returns

  - `{:ok, receipt}` - DeliveryReceipt if successful
  - `{:error, reason}` - If dispatch fails
  """
  def dispatch_channel(context, channel, event_config) do
    # Apply channel-level load (additional to event-level load)
    context = apply_channel_load(context, channel)

    # Resolve recipients for this channel
    recipients = resolve_recipients_for_channel(context, channel, event_config)

    # Filter out actor if exclude_actor is set
    recipients = filter_out_actor(recipients, context, channel)

    # Create one receipt per recipient
    results =
      Enum.map(recipients, fn recipient ->
        dispatch_to_recipient(context, channel, event_config, recipient)
      end)

    # Return success if at least one dispatch succeeded
    successful =
      Enum.filter(results, fn
        {:ok, _} -> true
        _ -> false
      end)

    if length(successful) > 0 do
      {:ok, Enum.map(successful, fn {:ok, receipt} -> receipt end)}
    else
      {:error, :all_dispatches_failed}
    end
  end

  # Dispatch to all channels with optional deduplication based on deduplicate_group
  # Channels with the same deduplicate_group are deduplicated - user gets max one notification per group
  defp dispatch_all_channels(channels, context, event_config) do
    # Check if any channels have deduplicate_group set
    has_dedup_groups? = Enum.any?(channels, & &1.deduplicate_group)

    if has_dedup_groups? do
      dispatch_with_deduplication(channels, context, event_config)
    else
      # No deduplication - dispatch each channel independently (default)
      Enum.map(channels, fn channel ->
        dispatch_channel(context, channel, event_config)
      end)
    end
  end

  # Dispatch channels with deduplication based on deduplicate_group
  defp dispatch_with_deduplication(channels, context, event_config) do
    # Collect all recipients from all channels with their channel info
    recipients_with_channels =
      Enum.flat_map(channels, fn channel ->
        channel_context = apply_channel_load(context, channel)
        recipients = resolve_recipients_for_channel(channel_context, channel, event_config)

        # Filter out actor if exclude_actor is set for this channel
        recipients = filter_out_actor(recipients, channel_context, channel)

        Enum.map(recipients, fn recipient ->
          {recipient, channel}
        end)
      end)

    # Apply deduplication - users in the same deduplicate_group get max one notification
    deduplicated_recipients = apply_group_deduplication(recipients_with_channels)

    # Dispatch to each recipient using their associated channel
    Enum.map(deduplicated_recipients, fn {recipient, channel} ->
      channel_context = apply_channel_load(context, channel)
      dispatch_to_recipient(channel_context, channel, event_config, recipient)
    end)
  end

  # Apply deduplication based on channel's deduplicate_group
  # Channels with same group are deduplicated - first channel (by DSL order) wins
  # Channels without a group are never deduplicated
  defp apply_group_deduplication(recipients_with_channels) do
    # Track which user IDs we've seen per dedup group
    {result, _seen} =
      Enum.reduce(recipients_with_channels, {[], %{}}, fn {recipient, channel} = item,
                                                          {acc, seen} ->
        user_id = get_user_id(recipient)
        dedup_group = channel.deduplicate_group

        cond do
          # No dedup group - always include
          is_nil(dedup_group) ->
            {[item | acc], seen}

          # Check if we've already seen this user in this dedup group
          MapSet.member?(Map.get(seen, dedup_group, MapSet.new()), user_id) ->
            # Skip - user already received notification for this group
            {acc, seen}

          true ->
            # First time seeing this user in this group - include and mark as seen
            new_seen =
              Map.update(seen, dedup_group, MapSet.new([user_id]), &MapSet.put(&1, user_id))

            {[item | acc], new_seen}
        end
      end)

    Enum.reverse(result)
  end

  # Private function that dispatches to a specific recipient
  defp dispatch_to_recipient(context, channel, event_config, recipient) do
    # Skip receipt creation for lightweight transports (e.g., :broadcast)
    if skip_receipt_for_transport?(channel.transport) do
      dispatch_without_receipt(context, channel, event_config, recipient)
    else
      dispatch_with_receipt(context, channel, event_config, recipient)
    end
  end

  defp skip_receipt_for_transport?(:broadcast), do: true
  defp skip_receipt_for_transport?(_), do: false

  defp extract_user_id_from_recipient(%{id: id}), do: id
  defp extract_user_id_from_recipient(%{"id" => id}), do: id
  defp extract_user_id_from_recipient(_), do: nil

  defp dispatch_without_receipt(context, channel, event_config, recipient) do
    # Build a minimal pseudo-receipt for the transport (no DB write)
    pseudo_receipt = %{
      id: nil,
      event_id: context.event_id,
      transport: channel.transport,
      audience: channel.audience,
      user_id: extract_user_id_from_recipient(recipient),
      content: %{},
      status: :pending,
      metadata: %{}
    }

    case dispatch_to_transport(pseudo_receipt, context, channel, event_config) do
      {:ok, _} ->
        Logger.debug("Broadcast dispatched: #{context.event_id} to #{channel.audience}")
        {:ok, :broadcast_sent}

      {:error, reason} ->
        Logger.warning("Broadcast failed: #{context.event_id} — #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp dispatch_with_receipt(context, channel, event_config, recipient) do
    case create_receipt(context, channel, event_config, recipient) do
      {:ok, :skipped_optional} ->
        # Optional channel that can't be delivered (e.g. SMS recipient
        # without a phone number). Counted as success — the channel
        # opted into "best-effort" delivery via `optional: true`.
        {:ok, :skipped_optional}

      {:ok, receipt} ->
        case dispatch_to_transport(receipt, context, channel, event_config) do
          {:ok, updated_receipt} ->
            Logger.debug("""
            Event dispatched successfully
            Event: #{context.event_id}
            Transport: #{channel.transport}
            Audience: #{channel.audience}
            Recipient: #{inspect(recipient)}
            Receipt ID: #{updated_receipt.id}
            Status: #{updated_receipt.status}
            """)

            # Broadcast counters if configured (once per recipient)
            broadcast_counters(context, channel, event_config)

            {:ok, updated_receipt}

          {:error, error} ->
            {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  # Private functions

  defp resolve_recipients_for_channel(context, channel, event_config) do
    # Resolve module with runtime fallback (handles compilation order issues)
    module = resolve_event_module(event_config, context)

    # Priority order for recipient resolution:
    # 1. recipient_resolver config (new DSL-based system)
    # 2. Event module recipients/2 callback (if returns non-empty)
    # 3. Legacy audience config (MFA-based)
    cond do
      # New: Use configured recipient resolver module
      resolver = Config.recipient_resolver() ->
        resource = extract_primary_resource(context)
        resolver.resolve(channel.audience, resource, context)

      # If there's a recipient_filter in event_config, use it (inline DSL or event-level config)
      not is_nil(event_config[:recipient_filter]) ->
        AshDispatch.Event.Helpers.resolve_recipients_for_audience(context, channel, event_config)

      # If there's a module, try its recipients callback first
      # But fall back to audience-based resolution if it returns empty
      not is_nil(module) ->
        case EventResolver.recipients(module, context, channel) do
          # Module returned recipients - use them
          recipients when is_list(recipients) and recipients != [] ->
            recipients

          # Module returned empty list - fall back to audience-based resolution
          # This handles both explicit empty returns and default [] from call_if_exported
          _ ->
            AshDispatch.Event.Helpers.resolve_recipients_for_audience(
              context,
              channel,
              event_config
            )
        end

      # Pure inline DSL without module - use helpers with app-level config
      true ->
        AshDispatch.Event.Helpers.resolve_recipients_for_audience(context, channel, event_config)
    end
  end

  # Extract the primary resource from context for recipient resolution
  defp extract_primary_resource(context) do
    # Priority order:
    # 1. Use resource_key if specified
    # 2. Look for common resource keys in data
    # 3. Return first struct found in data
    cond do
      context.resource_key && Map.has_key?(context.data, context.resource_key) ->
        Map.get(context.data, context.resource_key)

      true ->
        # Try common resource keys, then fall back to first struct
        common_keys = [:project, :lead, :order, :meeting, :business_plan, :offer, :phase]

        Enum.find_value(common_keys, fn key ->
          case Map.get(context.data, key) do
            value when is_struct(value) -> value
            _ -> nil
          end
        end) ||
          context.data
          |> Map.values()
          |> Enum.find(&is_struct/1)
    end
  end

  defp create_receipt(context, channel, event_config, recipient) do
    # Build full content for the receipt. Recipient is threaded in so
    # per-recipient locale resolution (recipient.locale) can flip the
    # rendered subject/body/text per recipient — multi-recipient channels
    # no longer share a single pre-rendered content blob when locales
    # differ.
    content = build_receipt_content(context, channel, event_config, recipient)

    # Extract recipient identifier and name using configured fields.
    # `:skip` is the soft-fail return when `channel.optional: true` and
    # the identifier can't be extracted — propagate up so the caller
    # skips this channel without crashing the whole dispatch.
    case extract_recipient_identifier(recipient, channel, event_config) do
      :skip ->
        {:ok, :skipped_optional}

      recipient_identifier ->
        do_create_receipt(context, channel, event_config, recipient, content, recipient_identifier)
    end
  end

  defp do_create_receipt(context, channel, event_config, recipient, content, recipient_identifier) do
    recipient_name = extract_recipient_name(recipient, channel, event_config)
    recipient_user_id = get_user_id(recipient)

    # Always link email receipts to in-app notifications for the same user/event
    # This enables skip_if_read policy and provides useful linking for analytics
    notification_id =
      if channel.transport == :email and recipient_user_id do
        find_in_app_notification_id(context.event_id, recipient_user_id)
      else
        nil
      end

    # Extract source resource info for linking (e.g., link receipt to order)
    {source_type, source_id} = extract_source_info(context, event_config)

    # Resolve locale for traceability (which template was rendered).
    # Per-recipient locale (recipient.locale) is considered so the receipt
    # records the actual locale that was used to render the recipient's
    # content blob.
    locale = resolve_channel_locale(channel, context, recipient)

    # Build receipt attributes
    attrs = %{
      event_id: context.event_id,
      transport: channel.transport,
      audience: channel.audience,
      recipient: recipient_identifier,
      user_id: recipient_user_id,
      notification_id: notification_id,
      source_type: source_type,
      source_id: source_id,
      locale: locale
      # Note: scheduled_for removed - Oban handles scheduling via schedule_in parameter
    }

    # Add recipient name to content if available
    content =
      if recipient_name do
        Map.put(content, :recipient_name, recipient_name)
      else
        content
      end

    # Add transport-specific content fields
    attrs =
      case channel.transport do
        :email ->
          Map.merge(attrs, %{
            subject: content[:subject],
            body_html: content[:html_body],
            body_text: content[:text_body],
            content: content
          })

        _ ->
          Map.put(attrs, :content, content)
      end

    # Create DeliveryReceipt
    # Use authorize?: false and skip_unknown_inputs to work within transaction context
    Config.delivery_receipt_resource()
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(authorize?: false, skip_unknown_inputs: [:notification_id])
  end

  # Extract recipient identifier using RecipientExtractor with cascading config.
  # When the channel is marked `optional: true` and the identifier can't be
  # extracted (e.g. SMS channel where the user has no phone_number), we
  # log + return `:skip` instead of crashing the whole dispatch — the
  # caller skips the receipt creation for this channel only.
  defp extract_recipient_identifier(recipient, channel, event_config) do
    RecipientExtractor.extract_identifier(
      recipient,
      channel.transport,
      channel.audience,
      event_config[:recipient]
    )
  rescue
    error ->
      if Map.get(channel, :optional, false) do
        Logger.info(
          "Skipping optional channel — recipient has no #{channel.transport} identifier " <>
            "(transport=#{channel.transport} audience=#{channel.audience})"
        )

        :skip
      else
        Logger.error("""
        Failed to extract recipient identifier
        Transport: #{channel.transport}
        Audience: #{channel.audience}
        Recipient: #{inspect(recipient)}
        Error: #{inspect(error)}
        """)

        reraise error, __STACKTRACE__
      end
  end

  # Extract recipient name using RecipientExtractor (returns nil if not configured)
  defp extract_recipient_name(recipient, channel, event_config) do
    RecipientExtractor.extract_name(
      recipient,
      channel.transport,
      channel.audience,
      event_config[:recipient]
    )
  rescue
    error ->
      Logger.warning("""
      Failed to extract recipient name (continuing with nil)
      Transport: #{channel.transport}
      Audience: #{channel.audience}
      Recipient: #{inspect(recipient)}
      Error: #{inspect(error)}
      """)

      nil
  end

  # Get user_id from recipient struct
  defp get_user_id(recipient) when is_map(recipient) do
    Map.get(recipient, :id)
  end

  defp get_user_id(_), do: nil

  # Filter out the actor (user who triggered the event) from recipients
  # Only applies when channel.exclude_actor is true and context.user is set
  defp filter_out_actor(recipients, %{user: %{id: actor_id}}, %{exclude_actor: true})
       when not is_nil(actor_id) do
    Enum.reject(recipients, fn recipient ->
      get_user_id(recipient) == actor_id
    end)
  end

  defp filter_out_actor(recipients, _context, _channel), do: recipients

  # Extract source resource info (type and ID) for linking receipts to source resources
  # Returns {source_type, source_id} tuple where values may be nil
  defp extract_source_info(context, event_config) do
    # Resolve module with runtime fallback (handles compilation order issues)
    module = resolve_event_module(event_config, context)

    cond do
      # Module-based events: use resource() callback to get the source type
      not is_nil(module) and not is_nil(EventResolver.resource(module)) ->
        resource_module = EventResolver.resource(module)
        resource_key = get_resource_key(module, context)

        case Map.get(context.data, resource_key) do
          %{id: id} = _record when not is_nil(id) ->
            {to_string(resource_module), id}

          _ ->
            {to_string(resource_module), nil}
        end

      # Inline DSL events: use resource_module from event_config if present
      not is_nil(event_config[:resource_module]) ->
        resource_module = event_config[:resource_module]
        resource_key = context.resource_key

        case Map.get(context.data, resource_key) do
          %{id: id} = _record when not is_nil(id) ->
            {to_string(resource_module), id}

          _ ->
            {to_string(resource_module), nil}
        end

      # No source info available
      true ->
        {nil, nil}
    end
  end

  # Get resource key from module callback or context
  defp get_resource_key(module, context) do
    # Use EventResolver for safe callback execution
    EventResolver.data_key(module) || context.resource_key
  end

  # Find the in-app notification ID for skip_if_read policy
  defp find_in_app_notification_id(event_id, user_id) do
    require Ash.Query

    case Config.delivery_receipt_resource()
         |> Ash.Query.filter(
           event_id == ^event_id and user_id == ^user_id and transport == :in_app
         )
         |> Ash.Query.select([:notification_id])
         |> Ash.Query.limit(1)
         |> Ash.read(authorize?: false) do
      {:ok, [receipt | _]} -> receipt.notification_id
      _ -> nil
    end
  end

  defp build_receipt_content(context, channel, event_config, recipient) do
    # Set per-recipient Gettext locale BEFORE rendering callbacks so any
    # `dgettext` invocations inside `prepare_template_assigns`,
    # `notification_title/message`, content-string interpolation, and
    # `EEx.eval_string` template rendering pick up the right locale.
    # This is the same backend referenced via the `:gettext_backend`
    # config — set to a no-op when not configured.
    #
    # `Gettext.put_locale/2` is process-local, so we wrap the body in
    # `try/after` to restore whatever locale was in effect when this
    # receipt started building. Without that, a worker that dispatches
    # to user A (locale="en") and then runs unrelated `t()` calls in
    # the same process would observe the leaked "en" locale until the
    # next explicit `put_locale`. See PR with regression test.
    prev_locale = current_locale()
    apply_recipient_locale(channel, context, recipient)

    try do
      do_build_receipt_content(context, channel, event_config, recipient)
    after
      restore_locale(prev_locale)
    end
  end

  defp do_build_receipt_content(context, channel, event_config, recipient) do
    # Resolve module with runtime fallback (handles compilation order issues)
    module = resolve_event_module(event_config, context)

    base_content =
      case module do
        nil ->
          # Pure inline DSL - use inline content only
          build_inline_content(context, channel, event_config, recipient)

        module ->
          # Hybrid mode: module + inline DSL
          # Step 1: Enhance context with module's prepare_template_assigns if available
          extra_assigns = safe_prepare_template_assigns(module, context, channel)

          enhanced_context =
            if map_size(extra_assigns) > 0 do
              # Add extra assigns to context variables
              Map.update(context, :variables, extra_assigns, fn vars ->
                Map.merge(vars, extra_assigns)
              end)
            else
              context
            end

          # Step 2: Build module content (with enhanced context)
          module_content =
            build_module_content(enhanced_context, channel, module, event_config, recipient)

          # Step 3: Check if there's inline DSL content to merge
          if has_inline_content?(event_config, channel) do
            # Build inline content with enhanced context (so interpolation has access to module assigns)
            inline_content =
              build_inline_content(enhanced_context, channel, event_config, recipient)

            # Inline DSL takes precedence over module callbacks
            Map.merge(module_content, inline_content)
          else
            # No inline DSL, use module content only
            module_content
          end
      end

    # Add policy to content if present on channel
    if channel.policy do
      Map.put(base_content, :policy, to_string(channel.policy))
    else
      base_content
    end
  end

  # Read the current process-level Gettext locale so `build_receipt_content/4`
  # can restore it after rendering. Returns nil when no backend is configured
  # or when `Gettext` isn't loaded.
  defp current_locale do
    case Config.gettext_backend() do
      nil ->
        nil

      backend ->
        if Code.ensure_loaded?(Gettext) do
          try do
            apply(Gettext, :get_locale, [backend])
          rescue
            _ -> nil
          end
        else
          nil
        end
    end
  end

  # Restore a previously-captured Gettext locale. Used in the `after`
  # block of `build_receipt_content/4` so per-recipient locale changes
  # don't leak to subsequent code paths in the same process.
  defp restore_locale(nil), do: :ok

  defp restore_locale(locale) when is_binary(locale) do
    case Config.gettext_backend() do
      nil ->
        :ok

      backend ->
        if Code.ensure_loaded?(Gettext) do
          try do
            apply(Gettext, :put_locale, [backend, locale])
            :ok
          rescue
            _ -> :ok
          end
        else
          :ok
        end
    end
  end

  # Set Gettext locale to the resolved per-channel-per-recipient locale.
  # No-op when no backend is configured or when the resolved locale is nil.
  defp apply_recipient_locale(channel, context, recipient) do
    case Config.gettext_backend() do
      nil ->
        :ok

      backend ->
        case resolve_channel_locale(channel, context, recipient) do
          locale when is_binary(locale) and locale != "" ->
            try do
              apply(Gettext, :put_locale, [backend, locale])
              :ok
            rescue
              _ -> :ok
            end

          _ ->
            :ok
        end
    end
  end

  # Check if there's inline DSL content configuration
  defp has_inline_content?(event_config, channel) do
    # Check if channel or event has content/metadata defined
    (channel.content && map_size(channel.content) > 0) ||
      (channel.metadata && map_size(channel.metadata) > 0) ||
      (event_config[:content] && length(event_config[:content]) > 0) ||
      (event_config[:metadata] && length(event_config[:metadata]) > 0)
  end

  defp build_inline_content(context, channel, event_config, recipient) do
    # Prefer channel-level content/metadata, fall back to event-level
    # This allows both patterns:
    # 1. Transport-specific: channels: [[transport: :email, content: [subject: "..."]]]
    # 2. Shared: content: [subject: "..."], channels: [[transport: :email]]
    channel_content = channel.content || %{}
    channel_metadata = channel.metadata || %{}
    event_content = (event_config[:content] || %{}) |> Enum.into(%{})
    event_metadata = (event_config[:metadata] || %{}) |> Enum.into(%{})

    # Merge with channel-level taking precedence
    content_config = Map.merge(event_content, channel_content)
    metadata_config = Map.merge(event_metadata, channel_metadata)

    base_content = %{
      transport: channel.transport,
      audience: channel.audience
    }

    # Add transport-specific content with variable interpolation
    transport_content =
      case channel.transport do
        :email ->
          # Try to render templates (convention-based or explicit path).
          # Recipient threaded through so locale resolution can pick
          # recipient.locale when present.
          {html_body, text_body} =
            render_inline_email_templates(context, channel, event_config, recipient)

          # Build content - only include fields with actual values (to not overwrite module callbacks in hybrid mode)
          %{}
          |> maybe_put(:from, content_config[:from_email])
          |> maybe_put(:subject, interpolate(content_config[:subject], context))
          |> maybe_put(:html_body, html_body)
          |> maybe_put(:text_body, text_body)

        :in_app ->
          # Build base content with required fields
          base = %{
            notification_type: metadata_config[:notification_type] || :info
          }

          # Add optional fields only if they have values (to not overwrite module callbacks in hybrid mode)
          base
          |> maybe_put(
            :title,
            interpolate(content_config[:title] || content_config[:notification_title], context)
          )
          |> maybe_put(
            :message,
            interpolate(
              content_config[:message] || content_config[:notification_message],
              context
            )
          )
          |> maybe_put(:action_url, interpolate(content_config[:action_url], context))
          |> maybe_put(:action_label, interpolate(content_config[:action_label], context))

        :discord ->
          %{
            message:
              interpolate(
                content_config[:message] || content_config[:notification_message],
                context
              ),
            webhook_url: channel.webhook_url
          }

        :slack ->
          %{
            message:
              interpolate(
                content_config[:message] || content_config[:notification_message],
                context
              ),
            webhook_url: channel.webhook_url
          }

        :sms ->
          %{
            message:
              interpolate(
                content_config[:message] || content_config[:notification_message],
                context
              )
          }

        :webhook ->
          %{
            payload: content_config[:webhook_payload] || %{},
            webhook_url: channel.webhook_url
          }
      end

    Map.merge(base_content, transport_content)
  end

  # Render email templates for inline DSL events
  defp render_inline_email_templates(context, channel, event_config, recipient) do
    # Get template configuration
    template_path = event_config[:template_path]
    event_id = context.event_id
    otp_app = get_otp_app(context)
    # Domain name for template path resolution
    domain = event_config[:domain]
    # Resource name for template path resolution
    resource_name = event_config[:resource_name]
    variant = channel.variant
    # Locale priority: channel.locale > channel.locale_from (dynamic) >
    # recipient.locale > context.locale
    locale = resolve_channel_locale(channel, context, recipient)

    # Prepare template assigns
    assigns = Context.template_assigns(context)

    # Try to render HTML template
    html =
      case AshDispatch.TemplateResolver.render(
             template_path: template_path,
             event_id: event_id,
             otp_app: otp_app,
             # Pass domain for correct path derivation
             domain: domain,
             # Pass resource_name for collision prevention
             resource_name: resource_name,
             format: :html,
             transport: :email,
             variant: variant,
             locale: locale,
             assigns: assigns
           ) do
        {:ok, rendered} ->
          rendered

        {:error, :template_not_found} ->
          nil

        {:error, error} ->
          Logger.warning("Failed to render HTML template for #{event_id}: #{inspect(error)}")
          nil
      end

    # Try to render text template
    text =
      case AshDispatch.TemplateResolver.render(
             template_path: template_path,
             event_id: event_id,
             otp_app: otp_app,
             # Pass domain for correct path derivation
             domain: domain,
             # Pass resource_name for collision prevention
             resource_name: resource_name,
             format: :text,
             transport: :email,
             variant: variant,
             locale: locale,
             assigns: assigns
           ) do
        {:ok, rendered} ->
          rendered

        {:error, :template_not_found} ->
          nil

        {:error, error} ->
          Logger.warning("Failed to render text template for #{event_id}: #{inspect(error)}")
          nil
      end

    {html, text}
  end

  # Get OTP app name from context or fallback to default
  defp get_otp_app(context) do
    # Try to extract from resource_module if available (for module-based events)
    resource_module = Map.get(context, :resource_module)

    if resource_module do
      case Atom.to_string(resource_module) do
        "Elixir." <> rest ->
          rest
          |> String.split(".")
          |> List.first()
          |> String.downcase()
          |> String.to_atom()

        _ ->
          :ash_dispatch
      end
    else
      # For inline DSL events, derive from event_id
      # e.g., "requests.new_reseller_request" -> extract "Magasin" from data key
      derive_otp_app_from_event_id(context.event_id)
    end
  end

  # Derive OTP app - use configured value (single source of truth)
  defp derive_otp_app_from_event_id(_event_id) do
    Config.otp_app() || :magasin
  end

  # Derive event directory from module name for file-based template loading
  # Uses Naming.module_directory for consistent path derivation
  # Example: Magasin.Accounts.Events.PasswordReset.Event -> lib/magasin/accounts/events/password_reset
  defp derive_event_dir_from_module(module, _otp_app) when is_atom(module) do
    # Use Naming for consistent path derivation
    relative_path = Naming.module_directory(module)

    # Convert to absolute path for file operations
    # In development/test: use source directory
    # In production: this won't be called (uses priv manifest instead)
    source_path = Path.join([File.cwd!(), relative_path])
    if File.exists?(source_path), do: source_path, else: nil
  rescue
    _ -> nil
  end

  defp derive_event_dir_from_module(_, _), do: nil

  # Interpolate variables in a string template
  defp interpolate(nil, _context), do: nil

  defp interpolate(template, context) when is_binary(template) do
    # Step 1: Translate via Gettext if backend configured
    translated = translate_content(template, context.locale)

    # Step 2: Variable interpolation ({{variable}} → value)
    assigns = Context.template_assigns(context)
    AshDispatch.VariableInterpolator.interpolate(translated, assigns, context.resource_key)
  end

  defp interpolate(value, _context), do: value

  # Translate content string via Gettext if a backend is configured.
  # The content string is the msgid, looked up in the configured domain
  # (`AshDispatch.Config.gettext_domain/0`, default `"notifications"`).
  # Gettext calls are dynamic to avoid requiring gettext as a dependency.
  #
  # **Locale handling:** if `locale` is non-nil we set it explicitly;
  # otherwise we trust the process-level locale that
  # `apply_recipient_locale/3` already put in place (per-recipient
  # resolution from 0.4.5). Previously this unconditionally reset the
  # locale to `"en"` for nil input, which silently undid recipient-locale
  # resolution for DSL-content lookups.
  defp translate_content(string, locale) do
    case AshDispatch.Config.gettext_backend() do
      nil ->
        string

      backend ->
        if Code.ensure_loaded?(Gettext) do
          if is_binary(locale) and locale != "" do
            apply(Gettext, :put_locale, [backend, locale])
          end

          apply(Gettext, :dgettext, [backend, AshDispatch.Config.gettext_domain(), string])
        else
          string
        end
    end
  end

  # Helper to conditionally add a key-value pair to a map only if value is not nil
  # This prevents overwriting module callback values with nil in hybrid mode
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp build_module_content(context, channel, module, _event_config, recipient) do
    base_content = %{
      transport: channel.transport,
      audience: channel.audience
    }

    # Add transport-specific content from callback module
    transport_content =
      case channel.transport do
        :email ->
          # Get variant for template resolution
          # Prefer channel.variant (from inline DSL) over EventResolver callback
          variant = channel.variant || EventResolver.template_variant(module, context, channel)
          # Locale priority: channel.locale > channel.locale_from (dynamic) >
          # recipient.locale > context.locale
          locale = resolve_channel_locale(channel, context, recipient)

          # Prepare template assigns using EventResolver
          base_assigns = safe_prepare_template_assigns(module, context, channel)

          # Merge context data and variables into assigns (variables take precedence)
          assigns =
            base_assigns
            |> Map.merge(Context.template_assigns(context))

          # Get subject early and add to assigns so layout template can access it
          subject = module.subject(context, channel)
          assigns_with_subject = Map.put(assigns, :subject, subject)

          # Check if module has body_html/body_text callbacks (for test modules without templates)
          {html_body, text_body} =
            if EventResolver.has_body_callbacks?(module) do
              # Use callbacks directly (for test modules or simple modules)
              {EventResolver.body_html(module, context, channel),
               EventResolver.body_text(module, context, channel)}
            else
              # Try to render templates using TemplateResolver (uses compiled templates or event_dir)
              # For hybrid mode with inline DSL, templates may not be found - that's OK,
              # inline DSL rendering will handle it

              # Derive OTP app from event_id for template resolution
              otp_app = derive_otp_app_from_event_id(context.event_id)

              # Derive event directory from module name for file-based loading in development
              event_dir = derive_event_dir_from_module(module, otp_app)

              html =
                case AshDispatch.TemplateResolver.render(
                       event_module: module,
                       event_dir: event_dir,
                       otp_app: otp_app,
                       format: :html,
                       transport: :email,
                       variant: variant,
                       locale: locale,
                       assigns: assigns_with_subject
                     ) do
                  {:ok, rendered} -> rendered
                  {:error, :template_not_found} -> nil
                  _ -> nil
                end

              text =
                case AshDispatch.TemplateResolver.render(
                       event_module: module,
                       event_dir: event_dir,
                       otp_app: otp_app,
                       format: :text,
                       transport: :email,
                       variant: variant,
                       locale: locale,
                       assigns: assigns_with_subject
                     ) do
                  {:ok, rendered} -> rendered
                  {:error, :template_not_found} -> nil
                  _ -> nil
                end

              {html, text}
            end

          # Get from as tuple and convert to map for JSON encoding
          {from_name, from_email} = module.from(context, channel)

          %{
            subject: subject,
            from: %{"name" => from_name, "email" => from_email},
            html_body: html_body,
            text_body: text_body
          }

        :in_app ->
          %{
            title: module.notification_title(context, channel),
            message: module.notification_message(context, channel),
            action_url: module.action_url(context, channel),
            action_label: module.action_label(context, channel),
            notification_type: get_notification_type(module, context)
          }

        _ ->
          # For other transports, use basic message
          %{
            message: module.notification_message(context, channel)
          }
      end

    Map.merge(base_content, transport_content)
  end

  defp get_notification_type(module, context) do
    # Use EventResolver for safe callback execution with default :info
    EventResolver.notification_type(module, context)
  end

  defp dispatch_to_transport(receipt, context, channel, event_config) do
    case channel.transport do
      :in_app ->
        Transports.InApp.deliver(receipt, context, channel, event_config)

      :email ->
        Transports.Email.deliver(receipt, context, channel, event_config)

      :discord ->
        Transports.Discord.deliver(receipt, context, channel, event_config)

      :slack ->
        Transports.Slack.deliver(receipt, context, channel, event_config)

      :sms ->
        Transports.SMS.deliver(receipt, context, channel, event_config)

      :webhook ->
        Transports.Webhook.deliver(receipt, context, channel, event_config)

      :broadcast ->
        Transports.Broadcast.deliver(receipt, context, channel, event_config)

      unknown ->
        Logger.warning("Unknown transport: #{unknown}, skipping delivery")

        receipt
        |> Ash.Changeset.for_update(:skip, %{error_message: "Unknown transport: #{unknown}"})
        |> Ash.update()
    end
  end

  # Helper to extract user from data map using Ash introspection
  # No hardcoded patterns - derives from Ash resource relationships
  defp extract_user_from_data(data) do
    user_module = Config.user_module()

    if is_nil(user_module) do
      Logger.warning("No :user_module configured in :ash_dispatch config")
      nil
    else
      # Strategy 1: Check if any value in data IS the user module struct
      Enum.find_value(data, fn {_key, value} ->
        if is_struct(value) && value.__struct__ == user_module do
          value
        end
      end) ||
        # Strategy 2: Use Ash introspection to find user via relationships
        find_user_via_ash_relationships(data, user_module) ||
        # Strategy 3: Accept bare map with :id under :user or :actor key
        # (manual pipeline events pass %{user: %{id: user_id}} without loading the full struct)
        extract_bare_user_map(data)
    end
  end

  defp extract_bare_user_map(data) do
    case data do
      %{user: %{id: _} = bare} when not is_struct(bare) -> bare
      %{actor: %{id: _} = bare} when not is_struct(bare) -> bare
      _ -> nil
    end
  end

  # Find user by introspecting Ash resource relationships
  # Works for ANY resource that has a relationship to User module
  defp find_user_via_ash_relationships(data, user_module) do
    Enum.find_value(data, fn {_key, resource} ->
      # Only process Ash resources
      if is_struct(resource) && Ash.Resource.Info.resource?(resource.__struct__) do
        # Get all relationships defined on this resource
        relationships = Ash.Resource.Info.relationships(resource.__struct__)

        # Find any relationship pointing to the configured User module
        user_relationship =
          Enum.find(relationships, fn rel ->
            rel.destination == user_module
          end)

        # Extract user from that relationship if found
        if user_relationship do
          Map.get(resource, user_relationship.name)
        end
      end
    end)
  end

  # Counter broadcasting integration
  defp broadcast_counters(context, channel, event_config) do
    counter_broadcaster = Config.counter_broadcaster()

    if counter_broadcaster && Code.ensure_loaded?(counter_broadcaster) &&
         function_exported?(counter_broadcaster, :broadcast, 3) do
      # Resolve module with runtime fallback (handles compilation order issues)
      module = resolve_event_module(event_config, context)

      # Hybrid mode: prefer inline DSL counters over module callback
      counters =
        cond do
          # Check if channel has counters defined in inline DSL
          is_list(channel.counters) and channel.counters != [] ->
            channel.counters

          # Fall back to event module callback using EventResolver
          not is_nil(module) ->
            EventResolver.counters(module, context, channel)

          # No counters defined
          true ->
            []
        end

      # Broadcast each counter via configured broadcaster
      Enum.each(counters, fn counter_name ->
        try do
          counter_broadcaster.broadcast(counter_name, context, channel)
        rescue
          error ->
            Logger.warning("""
            Failed to broadcast counter
            Counter: #{counter_name}
            Event: #{context.event_id}
            Error: #{inspect(error)}
            """)
        end
      end)
    end

    :ok
  end

  # Apply channel-level load to the primary resource in context
  defp apply_channel_load(context, %{load: []} = _channel), do: context
  defp apply_channel_load(context, %{load: nil} = _channel), do: context

  defp apply_channel_load(context, %{load: load} = _channel) when is_list(load) do
    # Get the primary resource from context.data using resource_key
    resource_key = context.resource_key

    case Map.get(context.data, resource_key) do
      nil ->
        # No primary resource to load, return context as-is
        context

      record when is_struct(record) ->
        # Load additional relationships on the record
        # Use Ash.Resource.Info.domain/1 to safely get the domain
        case Ash.Resource.Info.domain(record.__struct__) do
          nil ->
            Logger.warning("""
            Cannot load channel-level relationships #{inspect(load)}
            Resource #{inspect(record.__struct__)} has no domain configured
            Continuing with unloaded record...
            """)

            context

          domain ->
            case Ash.load(record, load, domain: domain, authorize?: false) do
              {:ok, loaded_record} ->
                # Update context with loaded record
                updated_data = Map.put(context.data, resource_key, loaded_record)
                %{context | data: updated_data}

              {:error, error} ->
                Logger.warning("""
                Failed to load channel-level relationships #{inspect(load)}
                Error: #{inspect(error)}
                Continuing with unloaded record...
                """)

                context
            end
        end

      _other ->
        # Not a struct, can't load
        context
    end
  end

  defp apply_channel_load(context, _channel), do: context

  # Always resolve event module at runtime via EventResolver
  # Compile-time resolution is unreliable due to module compilation order
  # (event modules compile after resources, so Code.ensure_loaded? fails)
  # Warning is only logged in dispatch_event.ex on first resolution failure
  defp resolve_event_module(_event_config, context) do
    case EventResolver.find_module(context.event_id) do
      {:ok, m} -> m
      {:error, :not_found} -> nil
    end
  end

  # Resolve locale for a channel with priority:
  # 1. channel.locale - static locale configured on channel
  # 2. channel.locale_from - dynamic locale from record field
  # 3. recipient.locale - per-recipient preference (NEW in 0.4.5; only
  #    consulted when the recipient struct carries a non-nil `:locale`
  #    field — typically a User record for `audience: :user`)
  # 4. context.locale - event-level locale (already resolved from record
  #    or default)
  @doc false
  def resolve_channel_locale(channel, context, recipient) do
    cond do
      # Static locale on channel has highest priority
      channel.locale ->
        channel.locale

      # Dynamic locale from record field. When the field is set but
      # the record's value is nil/missing, cascade through the rest of
      # the chain (recipient.locale → context.locale) instead of
      # bailing on `context.locale`. Makes `locale_from` describe a
      # *preference*, not a hard constraint.
      channel.locale_from ->
        record_locale(context, channel.locale_from) ||
          recipient_locale(recipient) || context.locale

      # Per-recipient locale (e.g. User.locale) — wins over the
      # event/resource-level fallback so each recipient sees their own
      # language.
      locale = recipient_locale(recipient) ->
        locale

      # Fall back to context locale (event-level)
      true ->
        context.locale
    end
  end

  # Extract `:locale` from a recipient struct/map. Returns nil if the
  # field is missing, nil, or not a non-empty binary — we explicitly
  # reject empty strings so a blank `User.locale` doesn't shadow
  # downstream fallbacks.
  defp recipient_locale(nil), do: nil

  defp recipient_locale(recipient) when is_map(recipient) do
    case Map.get(recipient, :locale) do
      locale when is_binary(locale) and locale != "" -> locale
      _ -> nil
    end
  end

  defp recipient_locale(_), do: nil

  # Read `locale_field` off `context.data[resource_key]`. Returns nil
  # (not `context.locale`) when missing so the caller controls the
  # cascade. Treats `%Ash.NotLoaded{}` as nil via RecordReader.
  defp record_locale(context, locale_field) do
    resource_key = context.resource_key

    case Map.get(context.data, resource_key) do
      record when is_map(record) -> RecordReader.safe_get(record, locale_field)
      _ -> nil
    end
  end


  # Wrap prepare_template_assigns with helpful error messages for unloaded relationships
  # Uses EventResolver for safe callback execution, but adds extra error handling for NotLoaded
  defp safe_prepare_template_assigns(module, context, channel) do
    # First check if the module exports the function
    if EventResolver.exports?(module, :prepare_template_assigns, 2) do
      try do
        module.prepare_template_assigns(context, channel)
      rescue
        e in KeyError ->
          reraise_with_load_hint(e, context, __STACKTRACE__)

        e in UndefinedFunctionError ->
          # Happens when trying to call functions on NotLoaded struct
          if String.contains?(Exception.message(e), "Ash.NotLoaded") do
            reraise_with_load_hint(e, context, __STACKTRACE__)
          else
            reraise e, __STACKTRACE__
          end

        e in Protocol.UndefinedError ->
          # Happens when trying to enumerate NotLoaded
          if String.contains?(Exception.message(e), "Ash.NotLoaded") do
            reraise_with_load_hint(e, context, __STACKTRACE__)
          else
            reraise e, __STACKTRACE__
          end
      end
    else
      %{}
    end
  end

  defp reraise_with_load_hint(original_error, context, stacktrace) do
    event_id = context.event_id
    original_message = Exception.message(original_error)

    message = """
    Failed to prepare template assigns for event "#{event_id}".

    #{original_message}

    This usually means a relationship wasn't loaded. Add it to the `load:` option in your event DSL:

        dispatch do
          event :your_event,
            trigger_on: :your_action,
            load: [:user, items: :product],  # <-- Add missing relationships here
            ...
        end

    Or for nested relationships:
        load: [:user, product_order_items: :product]
    """

    reraise RuntimeError.exception(message), stacktrace
  end
end
