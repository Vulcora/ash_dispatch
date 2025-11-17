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

  alias AshDispatch.{Context, Channel}
  alias AshDispatch.Transports
  alias AshDispatch.Resources.DeliveryReceipt

  require Logger

  @doc """
  Dispatches an event by ID with data.

  This is the high-level dispatch function that applications use.
  It looks up the event module, creates channels, and dispatches to all of them.

  ## Parameters

  - `event_id` - The event identifier (e.g., "requests.new_reseller_request")
  - `data` - Map of data for the event (e.g., %{reseller_request: request})

  ## Returns

  - `{:ok, results}` - List of delivery receipt results
  - `{:error, reason}` - If event not found or dispatch fails

  ## Examples

      # Dispatch a reseller request event
      AshDispatch.Dispatcher.dispatch(
        "requests.new_reseller_request",
        %{reseller_request: request}
      )

      # Dispatch an order created event
      AshDispatch.Dispatcher.dispatch(
        "orders.created",
        %{order: order, user: user}
      )
  """
  def dispatch(event_id, data) when is_binary(event_id) and is_map(data) do
    # Get event module from app config
    event_modules = Application.get_env(:ash_dispatch, :event_modules, [])

    case Enum.find(event_modules, fn {id, _module} -> id == event_id end) do
      {^event_id, event_module} ->
        # Create context
        context = %Context{
          event_id: event_id,
          data: data,
          user: extract_user_from_data(data)
        }

        # Get channels from event module
        channels = event_module.channels(context)

        # Build event config
        event_config = %{
          module: event_module
        }

        # Dispatch to all channels
        results =
          Enum.map(channels, fn channel ->
            dispatch(context, channel, event_config)
          end)

        # Return success if any dispatch succeeded
        if Enum.any?(results, fn
             {:ok, _} -> true
             _ -> false
           end) do
          {:ok, results}
        else
          {:error, :all_dispatches_failed}
        end

      nil ->
        Logger.error("Event module not found for event_id: #{event_id}")
        {:error, :event_not_found}
    end
  end

  @doc """
  Dispatches an event to a specific channel.

  Creates a DeliveryReceipt and routes to the appropriate transport handler.

  ## Parameters

  - `context` - Event context with all data
  - `channel` - Channel configuration (transport, audience, timing, etc.)
  - `event_config` - Event configuration (module, channels, content, metadata)

  ## Returns

  - `:ok` on success
  - `{:error, reason}` on failure

  ## Examples

      context = %Context{
        event_id: "product_order.created",
        data: %{order: order},
        user: user
      }

      channel = %Channel{
        transport: :email,
        audience: :user,
        time: {:in, 300}
      }

      Dispatcher.dispatch(context, channel, event_config)
  """
  def dispatch(context, channel, event_config) do
    with {:ok, receipt} <- create_receipt(context, channel, event_config),
         {:ok, updated_receipt} <- dispatch_to_transport(receipt, context, channel, event_config) do
      Logger.debug("""
      Event dispatched successfully
      Event: #{context.event_id}
      Transport: #{channel.transport}
      Audience: #{channel.audience}
      Receipt ID: #{updated_receipt.id}
      Status: #{updated_receipt.status}
      """)

      # Broadcast counters if configured
      broadcast_counters(context, channel, event_config)

      {:ok, updated_receipt}
    else
      {:error, reason} = error ->
        Logger.error("""
        Failed to dispatch event
        Event: #{context.event_id}
        Transport: #{channel.transport}
        Audience: #{channel.audience}
        Error: #{inspect(reason)}
        """)

        error
    end
  end

  # Private functions

  defp create_receipt(context, channel, event_config) do
    # Build full content for the receipt
    content = build_receipt_content(context, channel, event_config)

    # Determine recipient identifier
    recipient = resolve_recipient_identifier(context, channel)

    # Build receipt attributes
    attrs = %{
      event_id: context.event_id,
      transport: channel.transport,
      audience: channel.audience,
      recipient: recipient,
      scheduled_for: scheduled_time(channel)
    }

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
    DeliveryReceipt
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create()
  end

  defp resolve_recipient_identifier(context, channel) do
    case channel.audience do
      :user ->
        # Try to get user email or ID
        cond do
          is_map(context.user) and Map.has_key?(context.user, :email) ->
            context.user.email

          is_map(context.user) and Map.has_key?(context.user, :id) ->
            to_string(context.user.id)

          true ->
            "unknown_user"
        end

      :admin ->
        "admins"

      :system ->
        "system"
    end
  end

  defp build_receipt_content(context, channel, event_config) do
    case event_config[:module] do
      nil ->
        # Use inline content
        build_inline_content(context, channel, event_config)

      module ->
        # Use callback module
        build_module_content(context, channel, module)
    end
  end

  defp build_inline_content(context, channel, event_config) do
    content_config = event_config[:content] || %{}
    metadata_config = event_config[:metadata] || %{}

    base_content = %{
      transport: channel.transport,
      audience: channel.audience
    }

    # Add transport-specific content with variable interpolation
    transport_content =
      case channel.transport do
        :email ->
          %{
            subject: interpolate(content_config[:subject], context),
            from: content_config[:from_email] || default_from_email(),
            # HTML and text will be rendered by transport if templates exist
            html_body: nil,
            text_body: nil
          }

        :in_app ->
          %{
            title: interpolate(content_config[:notification_title], context),
            message: interpolate(content_config[:notification_message], context),
            action_url: interpolate(content_config[:action_url], context),
            notification_type: metadata_config[:notification_type] || :info
          }

        :discord ->
          %{
            message: interpolate(content_config[:notification_message], context),
            webhook_url: channel.webhook_url
          }

        :slack ->
          %{
            message: interpolate(content_config[:notification_message], context),
            webhook_url: channel.webhook_url
          }

        :sms ->
          %{
            message: interpolate(content_config[:notification_message], context)
          }

        :webhook ->
          %{
            payload: content_config[:webhook_payload] || %{},
            webhook_url: channel.webhook_url
          }
      end

    Map.merge(base_content, transport_content)
  end

  # Interpolate variables in a string template
  defp interpolate(nil, _context), do: nil
  defp interpolate(template, context) when is_binary(template) do
    AshDispatch.VariableInterpolator.interpolate(template, context.data, context.resource_key)
  end
  defp interpolate(value, _context), do: value

  defp build_module_content(context, channel, module) do
    base_content = %{
      transport: channel.transport,
      audience: channel.audience
    }

    # Add transport-specific content from callback module
    transport_content =
      case channel.transport do
        :email ->
          %{
            subject: module.subject(context, channel),
            from: module.from_email(context, channel),
            html_body: module.render_html_email(context, channel),
            text_body: module.render_text_email(context, channel)
          }

        :in_app ->
          %{
            title: module.notification_title(context, channel),
            message: module.notification_message(context, channel),
            action_url: module.action_url(context, channel),
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
    if function_exported?(module, :metadata, 1) do
      metadata = module.metadata(context)
      Map.get(metadata, :notification_type, :info)
    else
      :info
    end
  end

  defp default_from_email do
    Application.get_env(:ash_dispatch, :default_from_email, "noreply@example.com")
  end

  defp scheduled_time(%Channel{time: {:in, 0}}), do: DateTime.utc_now()

  defp scheduled_time(%Channel{time: {:in, seconds}}) do
    DateTime.utc_now()
    |> DateTime.add(seconds, :second)
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
    user_module = Application.get_env(:ash_dispatch, :user_module)

    if is_nil(user_module) do
      Logger.warning("No :user_module configured in :ash_dispatch config")
      nil
    else
      # Strategy 1: Check if any value in data IS the user module
      Enum.find_value(data, fn {_key, value} ->
        if is_struct(value) && value.__struct__ == user_module do
          value
        end
      end) ||
        # Strategy 2: Use Ash introspection to find user via relationships
        find_user_via_ash_relationships(data, user_module)
    end
  end

  # Find user by introspecting Ash resource relationships
  # Works for ANY resource that has a relationship to User module
  defp find_user_via_ash_relationships(data, user_module) do
    Enum.find_value(data, fn {_key, resource} ->
      # Only process Ash resources
      if is_struct(resource) && Ash.Resource.resource?(resource.__struct__) do
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
    counter_broadcaster = Application.get_env(:ash_dispatch, :counter_broadcaster)

    if counter_broadcaster && function_exported?(counter_broadcaster, :broadcast, 3) do
      # Get counters from event module
      module = event_config[:module]

      if module && function_exported?(module, :counters, 2) do
        counters = module.counters(context, channel)

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
    end

    :ok
  end
end
