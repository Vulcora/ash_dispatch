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

            {:error, _reason} ->
              # Deliberately not `inspect(reason)`: the endpoint is
              # unauthenticated unless you put `verify/3` in front of it, and
              # the reason distinguishes payloads a stranger can send. It is
              # in your log, where it belongs.
              json(conn, %{status: "error"})
          end
        end
      end
  """

  require Logger

  @doc """
  The header an outgoing message carries its tenant in, with
  `config :ash_dispatch, webhook_tenant_tag: true`. Public so a host can read
  it back out of a provider's payload itself.
  """
  @tenant_header "X-AshDispatch-Tenant"
  @spec tenant_header() :: String.t()
  def tenant_header, do: @tenant_header

  # plug_crypto is an optional dependency. Webhooks arrive through Plug, which
  # depends on it, so any app that can receive one has it.
  @compile {:no_warn_undefined, Plug.Crypto}

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
  - `opts`:
    - `:tenant` - the tenant whose receipts this request is about. **Required
      when receipts are stored per tenant**, because a provider webhook arrives
      with a message id and nothing else. Since 0.9.4

  ## Per-tenant receipts

  A webhook has to say which schema to look in, and it cannot be trusted to.
  Three ways, in the order to prefer them:

  1. **A per-tenant endpoint.** Your router already knows how to put a tenant
     in a path - `post "/webhooks/resend/:tenant"` - and you pass it here:

         Resend.process_webhook(params, tenant: conn.params["tenant"])

     Nothing depends on what the provider echoes back, so it works for every
     provider. This is the recommended setup, and it needs
     `config :ash_dispatch, tenants:` like the others: a path segment is a
     value from outside, and with per-tenant receipts it is a Postgres schema
     name. Without that configuration this path is refused, not trusted.
  2. **A provider tag.** With `config :ash_dispatch, webhook_tenant_tag: true`
     the outgoing message carries an `X-AshDispatch-Tenant` header, and this
     function will read it back out of the payload. Only switch it on behind
     `verify/3`: without a verified signature the tag is a value a stranger
     chose, and the tenant it names is a Postgres schema. It is also a header
     the recipient can see, so it must never say more than the tenant key.
  3. **Public receipts with `tenant_column: true`**, where webhooks work
     unchanged.

  Whichever it is, the tenant is held against `AshDispatch.Tenants` before any
  query — a route param too, since 0.9.4-rc.1 — and the receipt is then looked
  up **inside** that tenant. A webhook that names a tenant its receipt was not
  sent from therefore finds nothing: the id exists in one schema only. Nothing
  is fanned out across schemas looking for it - that would turn one indexed
  read into one per tenant, in the one place in the library an outsider can
  trigger work.

  ## Returns

  - `{:ok, receipt}` - Successfully processed webhook
  - `{:error, :not_found}` - Nothing was updated: no receipt has that
    `email_id` in the tenant this request is about, **or** the request named a
    tenant this host does not recognise or cannot check. One answer for both
    on purpose — telling them apart turns an unauthenticated POST into a
    tenant-existence oracle, and a tenant is a Postgres schema name, which is
    to say a customer's. Your log keeps the distinction
  - `{:error, :missing_email_id}` - Webhook missing email_id field
  - `{:error, :invalid_format}` - Webhook payload invalid
  """
  def process_webhook(params, opts \\ [])

  def process_webhook(%{"type" => event_type, "data" => data} = params, opts) do
    email_id = Map.get(data, "email_id")
    created_at = parse_timestamp(Map.get(params, "created_at"))

    Logger.info("Processing Resend webhook: #{event_type} for email_id=#{email_id}")

    with {:ok, tenant} <- tenant_for(data, opts),
         true <- not is_nil(email_id) do
      find_and_update(email_id, tenant, event_type, created_at, data)
    else
      false ->
        Logger.warning("Resend webhook missing email_id (type: #{inspect(params["type"])})")
        {:error, :missing_email_id}

      # A refused tenant answers exactly what an unknown message id answers.
      # The two used to differ, so an unauthenticated POST per candidate name
      # enumerated the host's schemas — its customers — and the controller
      # example in this module's own docs handed `inspect(reason)` back in the
      # response body. The log still says which it was.
      {:error, :unknown_tenant} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def process_webhook(params, _opts) do
    Logger.warning("Resend webhook invalid format (keys: #{inspect(webhook_keys(params))})")
    {:error, :invalid_format}
  end

  defp find_and_update(email_id, tenant, event_type, created_at, data) do
    resource = delivery_receipt_resource()

    result =
      resource
      |> Ash.Query.for_read(:get_by_provider_id, %{provider_id: email_id})
      |> Ash.read_one([authorize?: false] ++ AshDispatch.Tenancy.opts(resource, tenant))

    case result do
      {:ok, %{} = receipt} ->
        receipt
        |> AshDispatch.Tenancy.remember(tenant)
        |> update_receipt_from_event(event_type, created_at, data)

      {:ok, nil} ->
        Logger.warning("Resend webhook: delivery receipt not found for email_id=#{email_id}")
        {:error, :not_found}

      {:error, _} ->
        Logger.warning("Resend webhook: delivery receipt not found for email_id=#{email_id}")
        {:error, :not_found}
    end
  end

  # Which tenant this request may read. Both sources come from outside: a tag
  # is whatever the provider echoed, and a route param is whatever was in the
  # URL. Neither reaches a query unchecked.
  defp tenant_for(data, opts) do
    case Keyword.get(opts, :tenant) do
      nil -> payload_tenant(data)
      tenant -> route_tenant(tenant)
    end
  end

  defp payload_tenant(data) do
    if AshDispatch.Config.webhook_tenant_tag?() do
      case header_value(Map.get(data, "headers"), @tenant_header) do
        nil -> {:ok, nil}
        tenant -> check(tenant, allow_unchecked?: false)
      end
    else
      {:ok, nil}
    end
  end

  # A path segment comes from outside too. 0.9.4-rc.0 passed
  # `allow_unchecked?: true` here, so with `:tenants` absent — and the guide
  # presents this as the recommended setup without ever saying it needs
  # `:tenants` — the string in `POST /webhooks/resend/:tenant` went straight
  # into the `tenant:` option of a read, which is to say into a Postgres
  # `prefix:`, with no check and not even the warning the rest of the release
  # writes.
  #
  # Unchecked is allowed only where the value cannot choose a schema: a host
  # whose receipts are in the public schema, where `:tenant` means the column.
  defp route_tenant(tenant) do
    if AshDispatch.Tenancy.receipts_per_tenant?() do
      check(tenant, allow_unchecked?: false)
    else
      check(tenant, allow_unchecked?: true)
    end
  end

  defp check(tenant, opts) do
    case AshDispatch.Tenants.check(tenant) do
      :ok ->
        {:ok, tenant}

      {:error, :not_configured} ->
        AshDispatch.Tenants.warn_if_missing("A provider webhook names a tenant")

        if Keyword.fetch!(opts, :allow_unchecked?) do
          {:ok, tenant}
        else
          refuse(
            :not_configured,
            "Resend webhook: a request named a tenant and :tenants is not configured, so it " <>
              "cannot be checked. Refusing to read it. See AshDispatch.Tenants."
          )
        end

      {:error, :unknown_tenant} ->
        refuse(:unknown_tenant, "Resend webhook: refusing a tenant this host does not recognise.")
    end
  end

  # A log line at an endpoint a stranger can call in a loop. `Logger.error`
  # once per request was attacker-drivable volume at the level a host's
  # alerting watches; this is `warning`, once a minute per reason. The tenant
  # is not in the message or the key: it is the attacker's to choose, so
  # neither the log nor the throttle should grow with it.
  defp refuse(reason, message) do
    AshDispatch.Log.throttled({__MODULE__, reason}, fn -> Logger.warning(message) end)
    {:error, :unknown_tenant}
  end

  # Resend echoes custom headers as a list of `%{"name" => _, "value" => _}`;
  # a map is accepted too, because a gateway in between may normalise them.
  defp header_value(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn
      %{"name" => n, "value" => v} -> if downcase(n) == downcase(name), do: v
      {n, v} -> if downcase(n) == downcase(name), do: v
      _ -> nil
    end)
  end

  defp header_value(headers, name) when is_map(headers) do
    Enum.find_value(headers, fn {n, v} -> if downcase(n) == downcase(name), do: v end)
  end

  defp header_value(_headers, _name), do: nil

  defp downcase(value), do: value |> to_string() |> String.downcase()

  # Private functions

  # A webhook payload holds the recipient's address; the log gets its shape only.
  defp webhook_keys(%{} = params), do: params |> Map.keys() |> Enum.sort()
  defp webhook_keys(_other), do: :not_a_map

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
    |> AshDispatch.Tenancy.changeset_for_update(:record_webhook_event, attrs)
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
