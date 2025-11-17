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
end
