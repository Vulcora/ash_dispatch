defmodule AshDispatch.WebhookHandlers.Resend do
  @moduledoc """
  Handles webhooks from Resend for email delivery events.

  All events are tracked with dedicated timestamp fields for easy querying:

  ## Delivery Lifecycle Events
  - email.sent → sent_at
  - email.delivered → delivered_at
  - email.delivery_delayed → delivery_delayed_at
  - email.failed → failed_at

  ## Engagement Events
  - email.opened → opened_at
  - email.clicked → clicked_at

  ## Bounce/Complaint Events
  - email.bounced → bounced_at
  - email.complained → complained_at

  ## Other Events
  - email.received, email.scheduled → stored in provider_response only

  All events also store full webhook payload in provider_response for debugging.

  See: https://resend.com/docs/api-reference/webhooks

  ## Usage

  From a Phoenix controller:

      defmodule MyAppWeb.ResendWebhookController do
        use MyAppWeb, :controller
        alias AshDispatch.WebhookHandlers.Resend

        def handle(conn, params) do
          case Resend.process_webhook(params) do
            {:ok, _receipt} ->
              json(conn, %{status: "ok"})

            {:error, :not_found} ->
              json(conn, %{status: "ok", message: "receipt not found"})

            {:error, reason} ->
              json(conn, %{status: "error", message: inspect(reason)})
          end
        end
      end
  """

  require Logger
  alias AshDispatch.Resources.DeliveryReceipt

  @doc """
  Process a Resend webhook event.

  ## Parameters

  - `params` - Webhook payload from Resend containing:
    - `type` - Event type (e.g., "email.opened")
    - `created_at` - ISO 8601 timestamp
    - `data` - Event-specific data including `email_id`

  ## Returns

  - `{:ok, receipt}` - Successfully processed webhook
  - `{:error, :not_found}` - Delivery receipt not found for email_id
  - `{:error, :missing_email_id}` - Webhook missing email_id field
  - `{:error, :invalid_format}` - Webhook payload invalid
  - `{:error, reason}` - Other error
  """
  def process_webhook(%{"type" => event_type, "data" => data} = params) do
    email_id = Map.get(data, "email_id")
    created_at = parse_timestamp(Map.get(params, "created_at"))

    Logger.info("Processing Resend webhook: #{event_type} for email_id=#{email_id}")

    if email_id do
      # Find delivery receipt by provider_id (Resend email ID)
      case Ash.get(DeliveryReceipt, email_id,
             action: :get_by_provider_id,
             authorize?: false
           ) do
        {:ok, receipt} ->
          update_receipt_from_event(receipt, event_type, created_at, data)

        {:error, _} ->
          Logger.warning("Resend webhook: delivery receipt not found for email_id=#{email_id}")

          {:error, :not_found}
      end
    else
      Logger.warning("Resend webhook missing email_id: #{inspect(params)}")
      {:error, :missing_email_id}
    end
  end

  def process_webhook(params) do
    Logger.warning("Resend webhook invalid format: #{inspect(params)}")
    {:error, :invalid_format}
  end

  # Private functions

  defp update_receipt_from_event(receipt, event_type, timestamp, data) do
    attrs = build_update_attrs(event_type, timestamp, data)

    receipt
    |> Ash.Changeset.for_update(:record_webhook_event, attrs)
    |> Ash.update(authorize?: false)
  end

  # Delivery lifecycle events
  defp build_update_attrs("email.sent", timestamp, data) do
    %{
      sent_at: timestamp,
      provider_response: merge_provider_response(data)
    }
  end

  defp build_update_attrs("email.delivered", timestamp, data) do
    %{
      delivered_at: timestamp,
      provider_response: merge_provider_response(data)
    }
  end

  defp build_update_attrs("email.delivery_delayed", timestamp, data) do
    %{
      delivery_delayed_at: timestamp,
      provider_response: merge_provider_response(data)
    }
  end

  defp build_update_attrs("email.failed", timestamp, data) do
    %{
      failed_at: timestamp,
      provider_response: merge_provider_response(data)
    }
  end

  # Engagement events
  defp build_update_attrs("email.opened", timestamp, data) do
    %{
      opened_at: timestamp,
      provider_response: merge_provider_response(data)
    }
  end

  defp build_update_attrs("email.clicked", timestamp, data) do
    %{
      clicked_at: timestamp,
      provider_response: merge_provider_response(data)
    }
  end

  # Bounce/complaint events
  defp build_update_attrs("email.bounced", timestamp, data) do
    %{
      bounced_at: timestamp,
      provider_response: merge_provider_response(data)
    }
  end

  defp build_update_attrs("email.complained", timestamp, data) do
    %{
      complained_at: timestamp,
      provider_response: merge_provider_response(data)
    }
  end

  # Catch-all for any other events (e.g., email.received, email.scheduled)
  defp build_update_attrs(_event_type, _timestamp, data) do
    %{
      provider_response: merge_provider_response(data)
    }
  end

  defp merge_provider_response(new_data) do
    # Merge new webhook data with existing provider_response
    # This allows us to accumulate multiple webhook events
    Map.put(new_data, "webhook_received_at", DateTime.utc_now() |> DateTime.to_iso8601())
  end

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(iso8601_string) when is_binary(iso8601_string) do
    case DateTime.from_iso8601(iso8601_string) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> nil
    end
  end

  defp parse_timestamp(_), do: nil
end
