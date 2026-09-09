defmodule AshDispatch.Transports.Webhook do
  use AshDispatch.Transport, atom: :webhook, skip_receipt?: false

  @moduledoc """
  Generic webhook transport: POSTs the event to an HTTP endpoint, async via
  Oban (`AshDispatch.Workers.SendWebhook`).

  Use it when the receiver is a *system* rather than a person — a gateway that
  fans out to a chat product, an internal service that mirrors events, a
  partner integration.

  ## Configuration

      %Channel{
        transport: :webhook,
        audience: :user,
        webhook_url: "https://gateway.internal/dispatch",
        metadata: %{
          # Optional. When set, the request is signed (see "Signing").
          secret: System.get_env("GATEWAY_WEBHOOK_SECRET"),
          # Optional. Extra headers sent verbatim — useful for routing or for
          # telling the receiver which key to verify with.
          headers: %{"x-consumer" => "chat-gateway"}
        }
      }

  `webhook_url` may also come from `channel.opts["webhook_url"]`, matching the
  Slack transport.

  ## The payload

  A stable envelope, so a receiver can be written once:

      {
        "event_id":   "meetings.no_show",
        "receipt_id": "018f…",
        "user_id":    "9c2a…",      // null for non-user audiences
        "recipient":  "kim@example.com",
        "audience":   "user",
        "transport":  "webhook",
        "content":    { … },        // the rendered content map
        "metadata":   { … },        // channel metadata, minus `secret`
        "sent_at":    "2026-09-08T12:00:00Z"
      }

  `secret` is stripped from the forwarded metadata — a signing key must never
  travel inside the body it signs.

  ## Signing

  When `metadata.secret` is set the request carries

      <signature_header>: sha256=<lowercase hex>

  (default header `x-webhook-signature`, override with `metadata.signature_header`)
  computed as HMAC-SHA256 over

      METHOD "\\n" request_path "\\n" sorted_query ["\\n" raw_body]

  where `sorted_query` is the URL's query decoded, sorted by key and
  re-encoded, and the body part is present for POST/PATCH/PUT — which a webhook
  always is. Binding the *path and query* as well as the body means a captured
  signature cannot be replayed against a different endpoint on the same host.

  The signature covers the **exact bytes** that go on the wire: the transport
  serialises the JSON itself and hands the worker that string, rather than
  letting the HTTP client re-encode a map. Re-encoding is the classic way a
  webhook signature becomes intermittently wrong — key order and float
  formatting are not guaranteed to survive a round trip.

  ## Preferences

  This transport honours per-recipient opt-out via
  `AshDispatch.UserPreference.allows_receipt?/4`, like `:email` and `:in_app`.
  A webhook is frequently the first hop to a human (a chat DM, a push relay),
  and delivering to someone who opted out because the last hop happens to be
  HTTP would be the wrong default.

  > Note for maintainers: `:slack`, `:discord`, `:sms` and `:push` do **not**
  > check preferences today. That looks like a gap rather than a decision, but
  > changing them is a behaviour change for existing consumers and is left to
  > its own change.
  """

  alias AshDispatch.Channel
  alias AshDispatch.UserPreference
  alias AshDispatch.Workers.SendWebhook

  require Logger

  @default_signature_header "x-webhook-signature"

  def deliver(receipt, context, channel, event_config) do
    cond do
      not UserPreference.allows_receipt?(receipt, context, channel, event_config) ->
        Logger.info(
          "User #{inspect(Map.get(receipt, :user_id))} opted out of #{context.event_id} via :webhook, skipping"
        )

        skip(receipt, "user_opted_out")

      is_nil(webhook_url(channel)) ->
        Logger.warning(
          "Webhook transport missing webhook_url for receipt #{receipt.id}, skipping"
        )

        skip(receipt, "No webhook_url configured")

      true ->
        enqueue(receipt, context, channel)
    end
  end

  defp enqueue(receipt, context, channel) do
    url = webhook_url(channel)
    metadata = metadata(channel)
    body = Jason.encode!(envelope(receipt, context, channel, metadata))

    job_args = %{
      receipt_id: receipt.id,
      webhook_url: url,
      # `raw_body` is the signed representation; the worker sends it verbatim.
      raw_body: body,
      headers: request_headers(url, body, metadata)
    }

    # Schemalägg FÖRE insert. Från det ögonblick jobbet finns i kön kan en
    # worker plocka det — och med `Oban, testing: :inline` körs det redan
    # inuti `Oban.insert/1`. Sätter man `:scheduled` efteråt försöker man
    # flytta ett kvitto som hunnit bli `:sending`, `:sent` eller `:failed`,
    # och `schedule` går bara från `:pending`. Resultatet är ett kastat
    # `NoMatchingTransition` mitt i en lyckad leverans.
    scheduled =
      receipt
      |> Ash.Changeset.for_update(:schedule, %{})
      |> Ash.update!(authorize?: false)

    case job_args |> SendWebhook.new() |> Oban.insert() do
      {:ok, _job} ->
        Logger.info("Webhook job enqueued for receipt #{receipt.id}")
        # Läs om: har jobbet redan kört (inline, eller en snabb worker) är
        # `scheduled` en inaktuell bild, och att rapportera `:scheduled` för
        # något som redan är `:failed` vore precis den tysta grönskan
        # kvittona finns för att undvika.
        {:ok, aktuell(scheduled)}

      {:error, reason} ->
        Logger.error("Failed to enqueue webhook job: #{inspect(reason)}")

        updated =
          scheduled
          |> Ash.Changeset.for_update(:mark_failed, %{
            error_message: "Failed to enqueue: #{inspect(reason)}"
          })
          |> Ash.update!(authorize?: false)

        {:ok, updated}
    end
  end

  @doc """
  The JSON-serialisable envelope this transport POSTs.

  Public for the same reason as `canonical_string/3` and `request_headers/3`:
  a receiver should be able to build its parser against the real thing rather
  than against a description of it. Hand it the receipt, the context, the
  channel and the (already resolved) metadata and you get exactly the map that
  gets encoded.
  """
  @spec envelope(map(), map(), Channel.t(), map()) :: map()
  def envelope(receipt, context, channel, metadata) do
    %{
      "event_id" => Map.get(context, :event_id),
      "receipt_id" => receipt.id,
      "user_id" => Map.get(receipt, :user_id),
      # VAD händelsen handlar om. Utan det vet en mottagare att något hände
      # och till vem, men inte om vilket objekt — och kan därför inte erbjuda
      # en åtgärd. Kvittot bär redan fälten; de saknades bara i kuvertet.
      "source_type" => Map.get(receipt, :source_type),
      "source_id" => Map.get(receipt, :source_id),
      "recipient" => Map.get(receipt, :recipient),
      "audience" => to_string(channel.audience),
      "transport" => "webhook",
      "content" => content_map(receipt),
      # The signing key never travels inside the body it signs.
      "metadata" => metadata |> Map.drop(forbidden_metadata_keys()) |> stringify_keys(),
      "sent_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp content_map(receipt) do
    case Map.get(receipt, :content) do
      content when is_map(content) -> stringify_keys(content)
      _ -> %{}
    end
  end

  @doc """
  The headers the request will carry, signature included.

  Public for the same reason as `canonical_string/3`: the signing contract
  should be provable from the outside. Pass the channel metadata and you get
  back exactly what goes on the wire.
  """
  @spec request_headers(String.t(), String.t(), map()) :: map()
  def request_headers(url, body, metadata) do
    base =
      metadata
      |> meta_get(:headers, %{})
      |> stringify_keys()
      |> Map.put("Content-Type", "application/json")

    case hemlighet(metadata) do
      secret when is_binary(secret) and secret != "" ->
        header = meta_get(metadata, :signature_header, @default_signature_header)
        Map.put(base, to_string(header), "sha256=" <> signature(secret, url, body))

      _ ->
        base
    end
  end

  @doc """
  The signing secret for a channel: `metadata.secret`, or the value of the
  environment variable named by `metadata.secret_env`.

  `secret_env` exists because of a real tension. Channels declared in the
  `dispatch do` DSL are **compile-time** data, but a signing key is
  **runtime** data: baked in at compile time, a key rotation would not take
  effect until someone recompiled — and nothing would say so. The alternative
  was to move the whole channel into the event module's `channels/1` callback,
  which works but forfeits the DSL for every other property of that channel.

  Reading the name at compile time and the value at dispatch time keeps both:
  the channel stays declarative, and the key stays operational.

  `secret` wins when both are given, so an explicit value can override the
  environment in a test.
  """
  @spec hemlighet(map()) :: String.t() | nil
  def hemlighet(metadata) when is_map(metadata) do
    case meta_get(metadata, :secret) do
      s when is_binary(s) and s != "" ->
        s

      _ ->
        case meta_get(metadata, :secret_env) do
          namn when is_binary(namn) and namn != "" -> System.get_env(namn)
          _ -> nil
        end
    end
  end

  def hemlighet(_), do: nil

  # Metadata når oss med atom-nycklar från DSL:en och kan nå oss med
  # sträng-nycklar från en runtime-byggd map. Att bara läsa atomen vore tyst
  # farligt just för `secret`: strykningen nedan tar bort BÅDA formerna ur
  # payloaden, så en sträng-nycklad hemlighet hade försvunnit ur kroppen utan
  # att någonsin signera den — anropet går osignerat, utan ett ord.
  # Samma både-och-form som `AshDispatch.ContentMap.get_content/2`.
  defp meta_get(metadata, key, default \\ nil) when is_map(metadata) and is_atom(key) do
    case metadata[key] do
      nil -> metadata[Atom.to_string(key)] || default
      value -> value
    end
  end

  @doc """
  The canonical string a receiver must rebuild to verify a signature.

  Public so a consumer can test its own verifier against ours instead of
  against its reading of the docs.
  """
  @spec canonical_string(String.t(), String.t(), String.t()) :: String.t()
  def canonical_string(method, url, body) do
    uri = URI.parse(url)
    path = uri.path || "/"
    query = (uri.query || "") |> URI.decode_query() |> Enum.sort() |> URI.encode_query()
    base = method <> "\n" <> path <> "\n" <> query

    if method in ["POST", "PATCH", "PUT"], do: base <> "\n" <> body, else: base
  end

  defp signature(secret, url, body) do
    :crypto.mac(:hmac, :sha256, secret, canonical_string("POST", url, body))
    |> Base.encode16(case: :lower)
  end

  # Kvittots aktuella tillstånd. Har jobbet redan kört är den struct vi håller
  # inaktuell, och att rapportera `:scheduled` för något som redan är `:failed`
  # vore precis den tysta grönskan kvittona finns för att undvika.
  defp aktuell(receipt) do
    case AshDispatch.Config.delivery_receipt_resource()
         |> Ash.get(receipt.id, authorize?: false) do
      {:ok, farsk} -> farsk
      _ -> receipt
    end
  end

  defp webhook_url(%Channel{webhook_url: url}) when is_binary(url) and url != "", do: url

  defp webhook_url(%Channel{opts: opts}) when is_map(opts) do
    case opts["webhook_url"] || opts[:webhook_url] do
      url when is_binary(url) and url != "" -> url
      _ -> nil
    end
  end

  defp webhook_url(_), do: nil

  defp metadata(%Channel{metadata: metadata}) when is_map(metadata), do: metadata
  defp metadata(_), do: %{}

  defp forbidden_metadata_keys,
    do: [:secret, "secret", :secret_env, "secret_env", :signature_header, "signature_header"]

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify_keys(other), do: other

  defp skip(receipt, message) do
    updated =
      receipt
      |> Ash.Changeset.for_update(:skip, %{error_message: message})
      |> Ash.update!(authorize?: false)

    {:ok, updated}
  end
end
