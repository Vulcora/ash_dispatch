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
      outside and with per-tenant receipts it is a Postgres schema name. Read
      from `conn.path_params`, not `conn.params`, so a body key called
      "tenant" cannot name the schema.
    - `:tag` — let the handler read the `X-AshDispatch-Tenant` tag back out of
      the payload. Needs `config :ash_dispatch, webhook_tenant_tag: true`, or
      no outgoing message carries the tag; `init/1` says so at boot if it is
      missing. Only behind this plug, never without verification.

      With per-tenant receipts, a payload that carries **no** tag is a 400.
      That is not the exotic case: Resend's `opened` and `clicked` events
      carry no headers at all, and nor does any event about a message sent
      before the flag was switched on. Reading those as "no tenant" looked the
      message id up in the wrong schema, answered "not found", and returned
      200 — the webhook silently doing nothing, for ever. `{:path_param, …}`
      has no such gap, which is the other reason to prefer it.
    - `{module, function, args}` — called with the conn prepended.

    A **configured** source that yields nothing is a 400, not "no tenant". A
    typo'd route would otherwise look a message id up in the wrong schema,
    find nothing, and tell the provider everything was fine — for ever.
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
  - What is acted on is the **verified raw body**, decoded here — never
    `conn.params`. Those came out of a parser and may have had query-string or
    path params merged into them, and acting on a map nothing signed is the
    class of bug this plug exists to close.
  - An `{m, f, a}` of yours that raises — a vault that is down, a resolver
    that fails — is the same plain **400**, not a 500 with a stacktrace out of
    an unauthenticated route.
  """

  alias AshDispatch.WebhookHandlers.Resend

  require Logger

  # Plug is an optional dependency. This module is a plug by shape —
  # `init/1` and `call/2` — and names `Plug.Conn` only at runtime, so the
  # library compiles without Plug exactly as it did before.
  @compile {:no_warn_undefined, Plug.Conn}

  @doc false
  @spec init(keyword()) :: keyword()
  def init(opts) do
    if Keyword.get(opts, :tenant) == :tag and not AshDispatch.Config.webhook_tenant_tag?() do
      # Said once, at boot, where a configuration mistake belongs. Without the
      # tag switched on the outgoing message carries no
      # `X-AshDispatch-Tenant`, so the handler finds no tenant in the payload
      # and every webhook looks up a message id in the wrong schema — which
      # answers 200 and does nothing, for ever.
      IO.warn(
        "AshDispatch.Plugs.ResendWebhook: tenant: :tag, but " <>
          "`config :ash_dispatch, webhook_tenant_tag: true` is not set, so no outgoing " <>
          "message carries the tag this reads back."
      )
    end

    opts
  end

  @doc false
  @spec call(term(), keyword()) :: term()
  def call(conn, opts) do
    with {:ok, secret} <- secret(opts),
         {:ok, raw_body, conn} <- raw_body(conn),
         :ok <- verify(raw_body, conn, secret, opts),
         {:ok, params} <- params(raw_body) do
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
  rescue
    # An `{m, f, a}` of the host's own that raised — a vault that is down, a
    # key that is missing. The endpoint answers its plain 400 rather than
    # letting a 500 and a stacktrace out of an unauthenticated route, and
    # nothing is verified against a secret nobody has.
    error -> {:error, {:secret_raised, Exception.message(error)}}
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

  # The VERIFIED raw body, always. Never `conn.params`: those came out of a
  # parser, and what the signature covers is the bytes. The two are normally
  # the same map — and when they are not, acting on `conn.params` means acting
  # on something nothing signed, which is the whole class of bug this plug
  # exists to close. (A parser earlier in the pipeline merging query-string or
  # path params into `conn.params` is enough, and that is ordinary Phoenix.)
  #
  # Decoded after verification either way: an unverified request must not
  # reach a decoder, let alone a query.
  defp params(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, %{} = params} -> {:ok, params}
      _ -> {:error, :invalid_payload}
    end
  end

  # ── The tenant ──────────────────────────────────────────────────────

  # `{:ok, opts}` or `{:error, :no_tenant}`.
  #
  # A CONFIGURED source that yields nothing is a refusal, not "no tenant". The
  # first version degraded to `[]`, so a route whose `:tenant` segment was
  # missing — a typo'd path, a router change — looked up the message id with
  # no tenant at all and answered a cheerful 200. For a host with per-tenant
  # receipts that is the webhook silently doing nothing, for ever, with the
  # provider told everything is fine.
  defp tenant_opts(conn, params, opts) do
    case Keyword.get(opts, :tenant) do
      nil ->
        {:ok, []}

      {:path_param, name} ->
        # `path_params`, not `params`: `params` is whatever the parsers merged
        # together, and a body key called "tenant" must not be able to name
        # the schema. The path segment is the router's, and the router is ours.
        case Map.get(conn.path_params || %{}, to_string(name)) do
          value when is_binary(value) and value != "" -> {:ok, [tenant: value]}
          _ -> {:error, {:no_tenant, {:path_param, name}}}
        end

      :tag ->
        # The handler reads `X-AshDispatch-Tenant` out of the payload itself —
        # but only if there IS one. A payload with no tag made it look the
        # message id up with no tenant, in the wrong schema, which answers
        # "not found" and therefore a 200: the webhook silently doing nothing,
        # for ever. And a payload with no tag is not exotic — Resend's
        # `opened` and `clicked` events carry no headers at all, and nor does
        # any event about a message sent before the flag was switched on.
        #
        # Only when the receipts are per tenant: with public receipts the
        # tenant names a column, not a schema, and a missing tag costs
        # nothing.
        cond do
          not AshDispatch.Tenancy.receipts_per_tenant?() -> {:ok, []}
          Resend.tenant_tag(params) -> {:ok, []}
          true -> {:error, {:no_tenant, :tag}}
        end

      {module, function, args} ->
        case apply(module, function, [conn | args]) do
          nil -> {:error, {:no_tenant, {module, function}}}
          "" -> {:error, {:no_tenant, {module, function}}}
          tenant -> {:ok, [tenant: tenant]}
        end

      other ->
        Logger.warning(
          "[AshDispatch] ResendWebhook: tenant: #{inspect(other)} is not a source; ignored"
        )

        {:ok, []}
    end
  rescue
    error ->
      # A resolver of the host's own that raised. The endpoint answers its
      # plain 400 rather than letting a 500 and a stacktrace out of an
      # unauthenticated route.
      {:error, {:tenant_resolver_raised, Exception.message(error)}}
  end

  # ── Answering ───────────────────────────────────────────────────────

  defp process(conn, params, opts) do
    with {:ok, tenant_opts} <- tenant_opts(conn, params, opts) do
      case Resend.process_webhook(params, tenant_opts) do
        {:ok, _receipt} ->
          send(conn, 200, "ok")

        # No receipt with that message id, in the tenant this request is
        # about. Not this host's error, and a 4xx would have the provider
        # retrying it until it gave up.
        {:error, :not_found} ->
          send(conn, 200, "ok")

        {:error, reason} ->
          # Throttled, and the event type escaped: this is the one endpoint a
          # stranger can reach, and `inspect/1` of a value from the payload is
          # a way to write arbitrary text into the host's log at the level its
          # alerting watches.
          refuse(conn, {:rejected, reason, AshDispatch.Log.redact_text(type_of(params))})
      end
    else
      {:error, reason} -> refuse(conn, reason)
    end
  end

  # The event type, as a short, bounded string. From the payload, so it is a
  # stranger's value even behind a verified signature: a host sharing a
  # provider account gets its neighbour's events here.
  defp type_of(params) do
    case Map.get(params, "type") do
      type when is_binary(type) -> String.slice(type, 0, 64)
      _ -> "(none)"
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

  # The key must carry no value from the REQUEST, or rotating one defeats the
  # throttle — which is the point of throttling an endpoint a stranger can
  # reach.
  defp refusal_key({:unverified, _reason}), do: :unverified
  defp refusal_key({:no_tenant, _source}), do: :no_tenant
  defp refusal_key({:tenant_resolver_raised, _message}), do: :tenant_resolver_raised
  defp refusal_key({:secret_raised, _message}), do: :secret_raised
  defp refusal_key({:rejected, reason, _type}) when is_atom(reason), do: {:rejected, reason}
  defp refusal_key({:rejected, _reason, _type}), do: :rejected
  defp refusal_key(reason) when is_atom(reason), do: reason
  defp refusal_key(_reason), do: :other

  defp send(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(status, body)
    |> Plug.Conn.halt()
  end
end
