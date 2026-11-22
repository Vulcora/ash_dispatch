defmodule AshDispatch.Plugs.ResendWebhook do
  @moduledoc """
  The Resend delivery-webhook endpoint, verified and fail-closed.

  `AshDispatch.WebhookHandlers.Resend` has had `verify/4` since 0.5.4 and
  `process_webhook/2` for longer, and BACKLOG 4 said the plug that puts them
  together was still open. Four hosts wrote it — **one of them fail-open**,
  with a router that announced "verified by provider-specific signatures" while
  verifying nothing. An unverified endpoint here is receipt mutation by anyone
  who can guess a provider id.

  ## Setup

  The body reader first, because a signature can only be checked against the
  bytes that were signed:

      # endpoint.ex
      plug Plug.Parsers,
        parsers: [:urlencoded, :multipart, :json],
        pass: ["*/*"],
        json_decoder: Jason,
        body_reader: {AshDispatch.Plugs.RawBodyReader, :read_body, []}

  Then the route:

      # router.ex
      post "/webhooks/resend",
        AshDispatch.Plugs.ResendWebhook,
        secret: {:system, "RESEND_WEBHOOK_SECRET"}

  Or, in a pipeline of your own:

      forward "/webhooks/resend",
        to: AshDispatch.Plugs.ResendWebhook,
        init_opts: [secret: {:system, "RESEND_WEBHOOK_SECRET"}]

  ## Options

  - `:secret` — **required**. The `whsec_…` signing secret from Resend's
    dashboard. A literal string, `{:system, "VAR"}` read at request time (so a
    release reads its environment, not its build), or `{module, function,
    args}`.
  - `:tenant` — where the tenant comes from, for an installation with receipts
    per tenant:
    - `nil` (the default) — no tenant. Right for public receipts.
    - `{:path_param, "tenant"}` — a path segment, which is the recommended
      setup: `post "/webhooks/resend/:tenant"`. Needs
      `config :ash_dispatch, tenants:`, because a path segment is a value from
      outside and with per-tenant receipts it is a Postgres schema name.
    - `:tag` — let the handler read the `X-AshDispatch-Tenant` tag back out of
      the payload. Only behind this plug, never without verification.
    - `{module, function, args}` — called with the conn prepended.
  - `:tolerance_s` — the replay window, in seconds. Resend's default, 300,
    unless you say otherwise.

  ## What it answers

  - **200** — the receipt was updated, or there is no receipt with that
    message id. The second one is a 200 on purpose: a webhook about a message
    this host never sent is not this host's error, and a 4xx would make the
    provider retry it until it gave up.
  - **400** — anything else: no secret, no raw body, a signature that does not
    verify, a payload that is not a Resend event.

  The body is `ok` or `error` and **never a reason**. The endpoint is reachable
  by strangers, and a reason tells them apart: whether a tenant exists,
  whether a message id is known, whether the secret is configured. All of that
  is in your log, where it belongs.

  ## Fail-closed, specifically

  - A missing or unresolvable secret is a **400**, not a skipped check. There
    is no option that turns verification off; a plug that can be configured
    into fail-open is the bug this one exists to remove.
  - A missing raw body is a **400**. If `Plug.Parsers` consumed the body
    without `RawBodyReader`, there is nothing left to verify, and verifying
    nothing is the failure mode, not a degraded mode.
  - Verification runs **before** the payload is looked at, so an unverified
    request causes no read, no query and no tenant lookup.
  """

  alias AshDispatch.WebhookHandlers.Resend

  require Logger

  # Plug is an optional dependency. This module is a plug by shape —
  # `init/1` and `call/2` — and names `Plug.Conn` only at runtime, so the
  # library compiles without Plug exactly as it did before.
  @compile {:no_warn_undefined, Plug.Conn}

  @doc false
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @doc false
  @spec call(term(), keyword()) :: term()
  def call(conn, opts) do
    with {:ok, secret} <- secret(opts),
         {:ok, raw_body, conn} <- raw_body(conn),
         :ok <- verify(raw_body, conn, secret, opts),
         {:ok, params} <- params(conn, raw_body) do
      process(conn, params, opts)
    else
      {:error, reason} -> refuse(conn, reason)
    end
  end

  # ── The secret ──────────────────────────────────────────────────────

  defp secret(opts) do
    case resolve(Keyword.get(opts, :secret)) do
      secret when is_binary(secret) and secret != "" -> {:ok, secret}
      _ -> {:error, :no_secret}
    end
  end

  defp resolve({:system, var}) when is_binary(var), do: System.get_env(var)
  defp resolve({module, function, args}), do: apply(module, function, args)
  defp resolve(secret) when is_binary(secret), do: secret
  defp resolve(_other), do: nil

  # ── The body ────────────────────────────────────────────────────────

  # The reader's assign first. Then a direct read, for an endpoint that has not
  # parsed this path at all — which still works, and is why the plug can be
  # mounted without touching `Plug.Parsers`. Once a parser has consumed the
  # body without the reader there is nothing left, and that is a refusal.
  defp raw_body(conn) do
    case Map.get(conn.assigns, :raw_body) do
      body when is_binary(body) and body != "" ->
        {:ok, body, conn}

      _ ->
        case Plug.Conn.read_body(conn, []) do
          {:ok, body, conn} when is_binary(body) and body != "" -> {:ok, body, conn}
          {:ok, _empty, _conn} -> {:error, :no_raw_body}
          {:more, _partial, _conn} -> {:error, :body_too_large}
          _ -> {:error, :no_raw_body}
        end
    end
  rescue
    _ -> {:error, :no_raw_body}
  end

  # ── Verification ────────────────────────────────────────────────────

  defp verify(raw_body, conn, secret, opts) do
    headers =
      Map.new(["svix-id", "svix-timestamp", "svix-signature"], fn name ->
        {name, conn |> header(name) |> List.first()}
      end)

    verify_opts =
      case Keyword.fetch(opts, :tolerance_s) do
        {:ok, seconds} -> [tolerance_s: seconds]
        :error -> []
      end

    case Resend.verify(raw_body, headers, secret, verify_opts) do
      :ok -> :ok
      {:error, reason} -> {:error, {:unverified, reason}}
    end
  end

  defp header(conn, name), do: Plug.Conn.get_req_header(conn, name)

  # ── The payload ─────────────────────────────────────────────────────

  # `conn.params` when a parser has already decoded it, the raw body when it
  # has not. Decoded AFTER verification either way: an unverified request must
  # not reach a decoder, let alone a query.
  defp params(conn, raw_body) do
    case conn.params do
      %{"type" => _, "data" => _} = params -> {:ok, params}
      _ -> decode(raw_body)
    end
  end

  defp decode(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, %{} = params} -> {:ok, params}
      _ -> {:error, :invalid_payload}
    end
  end

  # ── The tenant ──────────────────────────────────────────────────────

  defp tenant_opts(conn, opts) do
    case Keyword.get(opts, :tenant) do
      nil ->
        []

      {:path_param, name} ->
        case Map.get(conn.params || %{}, to_string(name)) do
          value when is_binary(value) and value != "" -> [tenant: value]
          _ -> []
        end

      :tag ->
        # The handler reads `X-AshDispatch-Tenant` out of the payload itself.
        []

      {module, function, args} ->
        case apply(module, function, [conn | args]) do
          nil -> []
          tenant -> [tenant: tenant]
        end

      other ->
        Logger.warning(
          "[AshDispatch] ResendWebhook: tenant: #{inspect(other)} is not a source; ignored"
        )

        []
    end
  end

  # ── Answering ───────────────────────────────────────────────────────

  defp process(conn, params, opts) do
    case Resend.process_webhook(params, tenant_opts(conn, opts)) do
      {:ok, _receipt} ->
        send(conn, 200, "ok")

      # No receipt with that message id, in the tenant this request is about.
      # Not this host's error, and a 4xx would have the provider retrying it
      # until it gave up.
      {:error, :not_found} ->
        send(conn, 200, "ok")

      {:error, reason} ->
        Logger.warning("[AshDispatch] ResendWebhook: #{inspect(reason)}")
        send(conn, 400, "error")
    end
  end

  defp refuse(conn, reason) do
    # Throttled: this is the one endpoint in the library a stranger can reach,
    # and a log line per request is a way to fill the host's log at the level
    # its alerting watches. The KEY carries no value from the request, or
    # rotating one would defeat the throttle.
    AshDispatch.Log.throttled({__MODULE__, refusal_key(reason)}, fn ->
      Logger.warning("[AshDispatch] ResendWebhook refused a request: #{inspect(reason)}")
    end)

    send(conn, 400, "error")
  end

  defp refusal_key({:unverified, _reason}), do: :unverified
  defp refusal_key(reason) when is_atom(reason), do: reason
  defp refusal_key(_reason), do: :other

  defp send(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(status, body)
    |> Plug.Conn.halt()
  end
end
