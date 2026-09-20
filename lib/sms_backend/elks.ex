defmodule AshDispatch.SMSBackend.Elks do
  @moduledoc """
  SMS-backend för [46elks](https://46elks.se), den svenska SMS-leverantören.

  Paketerad som `AshDispatch.EmailBackend.Swoosh` är det: biblioteket äger
  transporten, kvittot och omförsöken, och en konkret leverantör ligger bakom
  en optionell dep. Här är depen `req`.

  ## Konfiguration

      config :ash_dispatch, :sms_backend, AshDispatch.SMSBackend.Elks

      config :ash_dispatch, AshDispatch.SMSBackend.Elks,
        username: System.get_env("ELKS_API_USERNAME"),
        password: System.get_env("ELKS_API_PASSWORD"),
        from: System.get_env("ELKS_SMS_FROM") || "Notis",
        dryrun: false

  Och mottagarfältet, som är lätt att glömma och vars felmeddelande inte säger
  var man ska leta:

      config :ash_dispatch,
        recipient_fields: [
          sms: [identifier: :phone, name: [:display_name, :name]]
        ]

  ## Testning

  `:req_options` skickas rakt in i `Req.post/2`, så en stubb kan sättas utan
  att backenden känner till testet:

      config :ash_dispatch, AshDispatch.SMSBackend.Elks,
        req_options: [plug: {Req.Test, MyApp.Elks}]

  ## `dryrun`

  Sätt `dryrun: true` i dev och test. 46elks tar då emot anropet, validerar
  det och svarar med ett id — men skickar ingenting och debiterar inget.
  Kvittot markeras `:sent` med ett `provider_id` prefixat `dryrun:`, så spåret
  blir komplett utan att någon får ett SMS.

  ## Avsändare

  Ett alfanumeriskt avsändar-id får vara högst elva tecken och kan inte tas
  emot svar på. Ett telefonnummer i E.164 kan det. 46elks registrerar
  alfanumeriska avsändare per konto.

  ## Fel som inte är värda ett omförsök

  `400`, `401` och `403` markeras `:failed_permanent` direkt. Ett feltypat
  telefonnummer blir inte rätt av att skickas om fem gånger, och ett fel
  lösenord blir inte rätt alls — att bränna omförsöken på dem fördröjer bara
  beskedet till människan som ska rätta det.
  """

  @behaviour AshDispatch.SMSBackend

  alias AshDispatch.ContentMap
  alias AshDispatch.ReceiptStatus
  alias AshDispatch.SMSBackend.Phone

  require Logger

  @endpoint "https://api.46elks.com/a1/sms"

  @impl AshDispatch.SMSBackend
  def deliver(receipt, _context, _channel, _event_config) do
    with {:ok, config} <- config(),
         {:ok, to} <- nummer(receipt),
         {:ok, body} <- body(receipt) do
      post(receipt, config, to, body)
    else
      {:error, {:permanent, reason}} ->
        {:ok, ReceiptStatus.mark_failed_permanent(receipt, reason)}

      {:error, reason} ->
        {:ok, ReceiptStatus.mark_failed(receipt, reason)}
    end
  end

  # Phone.to_e164/1 svarar bart :error. Ett nummer som inte går att tolka blir
  # inte tolkbart av att skickas om, så det är permanent.
  defp nummer(receipt) do
    case Phone.to_e164(receipt.recipient) do
      {:ok, e164} -> {:ok, e164}
      :error -> {:error, {:permanent, "oanvändbart telefonnummer: #{inspect(receipt.recipient)}"}}
    end
  end

  defp post(receipt, config, to, body) do
    form =
      %{from: config[:from], to: to, message: body}
      |> maybe_dryrun(config)

    # retry: false med flit. Kvittot äger omförsöken, och Reqs egna skulle
    # kunna skicka ett andra SMS på en 500 som faktiskt gick fram.
    opts =
      [
        auth: {:basic, "#{config[:username]}:#{config[:password]}"},
        form: form,
        receive_timeout: 15_000,
        retry: false
      ] ++ Keyword.get(config, :req_options, [])

    request = Req.post(@endpoint, opts)

    case request do
      {:ok, %{status: status, body: resp}} when status in 200..299 ->
        {:ok, ReceiptStatus.mark_sent(receipt, provider_response(resp, config))}

      {:ok, %{status: status, body: resp}} when status in [400, 401, 403] ->
        {:ok,
         ReceiptStatus.mark_failed_permanent(
           receipt,
           "46elks #{status}: #{felstext(resp)}"
         )}

      {:ok, %{status: status, body: resp}} ->
        {:ok, ReceiptStatus.mark_failed(receipt, "46elks #{status}: #{felstext(resp)}")}

      {:error, reason} ->
        {:ok, ReceiptStatus.mark_failed(receipt, "46elks: #{inspect(reason)}")}
    end
  end

  defp maybe_dryrun(form, config) do
    if config[:dryrun], do: Map.put(form, :dryrun, "yes"), else: form
  end

  defp provider_response(resp, config) when is_map(resp) do
    id = resp["id"] || resp[:id]
    if config[:dryrun], do: Map.put(resp, "id", "dryrun:#{id}"), else: resp
  end

  defp provider_response(resp, _config), do: %{"raw" => to_string(resp)}

  defp felstext(resp) when is_binary(resp), do: resp
  defp felstext(resp) when is_map(resp), do: resp["message"] || inspect(resp)
  defp felstext(resp), do: inspect(resp)

  # Dispatchern skriver `:message` (dispatcher.ex, content-byggaren för
  # non-email), men kvittot är en JSONB-kolumn och kommer tillbaka
  # strängnycklad ur Postgres. ContentMap hanterar båda.
  defp body(receipt) do
    case ContentMap.get_content(receipt.content, :message) ||
           ContentMap.get_content(receipt.content, :body) do
      text when is_binary(text) ->
        trimmed = String.trim(text)
        if trimmed == "", do: {:error, {:permanent, "tom sms-text"}}, else: {:ok, trimmed}

      _ ->
        {:error, {:permanent, "kvittot saknar sms-text"}}
    end
  end

  defp config do
    config = Application.get_env(:ash_dispatch, __MODULE__, [])

    cond do
      not Code.ensure_loaded?(Req) ->
        {:error, "req saknas — lägg till {:req, \"~> 0.5\"} för att använda Elks-backenden"}

      blank?(config[:username]) or blank?(config[:password]) ->
        {:error, "46elks är inte konfigurerad (username/password saknas)"}

      true ->
        {:ok, Keyword.put_new(config, :from, "Notis")}
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
