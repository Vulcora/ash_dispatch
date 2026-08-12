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

  @default_tolerance_s 300

  @doc """
  Verifies a Resend webhook's Svix signature before you hand the payload to
  `process_webhook/1`. Without this the endpoint is unauthenticated receipt
  mutation — anyone who guesses a provider id can mark mail opened/bounced.

  Resend signs `"svix-id.svix-timestamp.raw_body"` with HMAC-SHA256 using
  the base64 key from the `whsec_`-prefixed signing secret, base64-encoding
  the result. The `svix-signature` header can carry several space-separated
  `v1,<sig>` entries during secret rotation — any match passes. Comparison
  is constant-time; the timestamp must be within `:tolerance_s` seconds
  (default #{@default_tolerance_s}) of now.

  ## Parameters

  - `raw_body` - the request body EXACTLY as received (cache it before your
    JSON parser consumes it — a re-encoded body will not verify)
  - `headers` - map with `"svix-id"`, `"svix-timestamp"`, `"svix-signature"`
    (e.g. built from `Plug.Conn.get_req_header/2`)
  - `secret` - the signing secret from Resend's dashboard (`whsec_...`)
  - `opts` - `:tolerance_s` (replay window), `:now` (unix seconds, for tests)

  ## Returns

  - `:ok` on a valid signature
  - `{:error, :missing_headers | :invalid_secret | :invalid_timestamp |
    :stale_timestamp | :signature_mismatch}`

  ## Example (Phoenix controller)

      def handle(conn, params) do
        raw = conn.assigns[:raw_body]
        headers = %{
          "svix-id" => List.first(get_req_header(conn, "svix-id")),
          "svix-timestamp" => List.first(get_req_header(conn, "svix-timestamp")),
          "svix-signature" => List.first(get_req_header(conn, "svix-signature"))
        }

        case Resend.verify(raw, headers, System.fetch_env!("RESEND_WEBHOOK_SECRET")) do
          :ok -> # ... Resend.process_webhook(params)
          {:error, _} -> conn |> put_status(400) |> json(%{error: "invalid signature"})
        end
      end
  """
  def verify(raw_body, headers, secret, opts \\ [])

  def verify(raw_body, %{} = headers, secret, opts) when is_binary(raw_body) do
    with {:ok, id, ts, signatures} <- required_headers(headers),
         {:ok, key} <- decode_secret(secret),
         :ok <- check_freshness(ts, opts) do
      expected = Base.encode64(:crypto.mac(:hmac, :sha256, key, "#{id}.#{ts}.#{raw_body}"))

      valid? =
        signatures
        |> String.split(" ", trim: true)
        |> Enum.any?(fn entry ->
          case String.split(entry, ",", parts: 2) do
            ["v1", sig] -> Plug.Crypto.secure_compare(sig, expected)
            _ -> false
          end
        end)

      if valid?, do: :ok, else: {:error, :signature_mismatch}
    end
  end

  defp required_headers(headers) do
    with id when is_binary(id) and id != "" <- headers["svix-id"],
         ts when is_binary(ts) and ts != "" <- headers["svix-timestamp"],
         sigs when is_binary(sigs) and sigs != "" <- headers["svix-signature"] do
      {:ok, id, ts, sigs}
    else
      _ -> {:error, :missing_headers}
    end
  end

  defp decode_secret("whsec_" <> b64), do: decode_secret(b64)

  defp decode_secret(b64) when is_binary(b64) do
    case Base.decode64(b64) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, :invalid_secret}
    end
  end

  defp decode_secret(_), do: {:error, :invalid_secret}

  defp check_freshness(ts, opts) do
    tolerance = Keyword.get(opts, :tolerance_s, @default_tolerance_s)
    now = Keyword.get(opts, :now, System.system_time(:second))

    case Integer.parse(ts) do
      {t, ""} ->
        if abs(now - t) <= tolerance, do: :ok, else: {:error, :stale_timestamp}

      _ ->
        {:error, :invalid_timestamp}
    end
  end

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
      result =
        delivery_receipt_resource()
        |> Ash.Query.for_read(:get_by_provider_id, %{provider_id: email_id})
        |> Ash.read_one(authorize?: false)

      case result do
        {:ok, %{} = receipt} ->
          update_receipt_from_event(receipt, event_type, created_at, data)

        {:ok, nil} ->
          Logger.warning("Resend webhook: delivery receipt not found for email_id=#{email_id}")
          {:error, :not_found}

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

  defp delivery_receipt_resource do
    Application.get_env(:ash_dispatch, :delivery_receipt_resource) ||
      raise """
      AshDispatch: :delivery_receipt_resource not configured!

      Add to your config/config.exs:

        config :ash_dispatch,
          delivery_receipt_resource: MyApp.Deliveries.DeliveryReceipt
      """
  end

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
      provider_response: webhook_event_entry("email.sent", data)
    }
  end

  defp build_update_attrs("email.delivered", timestamp, data) do
    %{
      delivered_at: timestamp,
      provider_response: webhook_event_entry("email.delivered", data)
    }
  end

  defp build_update_attrs("email.delivery_delayed", timestamp, data) do
    %{
      delivery_delayed_at: timestamp,
      provider_response: webhook_event_entry("email.delivery_delayed", data)
    }
  end

  defp build_update_attrs("email.failed", timestamp, data) do
    %{
      failed_at: timestamp,
      provider_response: webhook_event_entry("email.failed", data)
    }
  end

  # Engagement events
  defp build_update_attrs("email.opened", timestamp, data) do
    %{
      opened_at: timestamp,
      provider_response: webhook_event_entry("email.opened", data)
    }
  end

  defp build_update_attrs("email.clicked", timestamp, data) do
    %{
      clicked_at: timestamp,
      provider_response: webhook_event_entry("email.clicked", data)
    }
  end

  # Bounce/complaint events
  defp build_update_attrs("email.bounced", timestamp, data) do
    %{
      bounced_at: timestamp,
      provider_response: webhook_event_entry("email.bounced", data)
    }
  end

  defp build_update_attrs("email.complained", timestamp, data) do
    %{
      complained_at: timestamp,
      provider_response: webhook_event_entry("email.complained", data)
    }
  end

  # Catch-all for any other events (e.g., email.received, email.scheduled)
  defp build_update_attrs(event_type, _timestamp, data) do
    %{
      provider_response: webhook_event_entry(event_type, data)
    }
  end

  # Namespace each webhook payload under its event type so successive events
  # accumulate on the receipt instead of overwriting each other — the actual
  # merge with the existing provider_response happens in the receipt's
  # :record_webhook_event action. The original send response keeps its
  # top-level keys; event entries cannot collide with it.
  defp webhook_event_entry(event_type, data) do
    %{
      event_type =>
        Map.put(data, "webhook_received_at", DateTime.utc_now() |> DateTime.to_iso8601())
    }
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
