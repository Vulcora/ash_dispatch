defmodule AshDispatch.SMSBackend.Elks do
  @moduledoc """
  SMS backend for [46elks](https://46elks.com), a Nordic SMS provider.

  Packaged the way `AshDispatch.EmailBackend.Swoosh` is: the library owns the
  transport, the receipt and the retries, and a concrete provider sits behind
  an optional dependency. Here that dependency is `req`.

  ## Configuration

      config :ash_dispatch, :sms_backend, AshDispatch.SMSBackend.Elks

      config :ash_dispatch, AshDispatch.SMSBackend.Elks,
        username: System.get_env("ELKS_API_USERNAME"),
        password: System.get_env("ELKS_API_PASSWORD"),
        from: System.get_env("ELKS_SMS_FROM") || "Notify",
        dryrun: false

  And the recipient field, which is easy to forget and whose error message
  does not say where to look:

      config :ash_dispatch,
        recipient_fields: [
          sms: [identifier: :phone, name: [:display_name, :name]]
        ]

  ## Testing

  `:req_options` is passed straight into `Req.post/2`, so a stub can be
  installed without the backend knowing about the test:

      config :ash_dispatch, AshDispatch.SMSBackend.Elks,
        req_options: [plug: {Req.Test, MyApp.Elks}]

  ## `dryrun`

  Set `dryrun: true` in dev and test. 46elks then accepts the request,
  validates it and answers with an id — but sends nothing and charges nothing.
  The receipt is marked `:sent` with a `provider_id` prefixed `dryrun:`, so the
  trail is complete without anyone receiving a message.

  ## Sender

  An alphanumeric sender id may be at most eleven characters and cannot be
  replied to. A phone number in E.164 can. 46elks registers alphanumeric
  senders per account.

  ## Failures not worth retrying

  `400`, `401` and `403` are marked `:failed_permanent` immediately. A
  malformed phone number does not become valid by being sent five more times,
  and a wrong password never does — burning the retries on them only delays
  telling the person who can fix it.
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
         {:ok, to} <- number(receipt),
         {:ok, body} <- body(receipt) do
      post(receipt, config, to, body)
    else
      {:error, {:permanent, reason}} ->
        {:ok, ReceiptStatus.mark_failed_permanent(receipt, reason)}

      {:error, reason} ->
        {:ok, ReceiptStatus.mark_failed(receipt, reason)}
    end
  end

  # Phone.to_e164/1 answers a bare :error. A number that cannot be parsed does
  # not become parseable by being resent, so it is permanent.
  defp number(receipt) do
    case Phone.to_e164(receipt.recipient) do
      {:ok, e164} -> {:ok, e164}
      :error -> {:error, {:permanent, "unusable phone number: #{inspect(receipt.recipient)}"}}
    end
  end

  defp post(receipt, config, to, body) do
    form =
      %{from: config[:from], to: to, message: body}
      |> maybe_dryrun(config)

    # retry: false deliberately. The receipt owns the retries, and Req's own
    # would happily send a second message on a 500 that actually went through.
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
           "46elks #{status}: #{error_text(resp)}"
         )}

      {:ok, %{status: status, body: resp}} ->
        {:ok, ReceiptStatus.mark_failed(receipt, "46elks #{status}: #{error_text(resp)}")}

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

  defp error_text(resp) when is_binary(resp), do: resp
  defp error_text(resp) when is_map(resp), do: resp["message"] || inspect(resp)
  defp error_text(resp), do: inspect(resp)

  # The dispatcher writes `:message` (see the non-email content builder in
  # dispatcher.ex), but the receipt's content is a JSONB column and comes back
  # string-keyed from Postgres. ContentMap handles both.
  defp body(receipt) do
    case ContentMap.get_content(receipt.content, :message) ||
           ContentMap.get_content(receipt.content, :body) do
      text when is_binary(text) ->
        trimmed = String.trim(text)
        if trimmed == "", do: {:error, {:permanent, "empty sms body"}}, else: {:ok, trimmed}

      _ ->
        {:error, {:permanent, "receipt carries no sms body"}}
    end
  end

  defp config do
    config = Application.get_env(:ash_dispatch, __MODULE__, [])

    cond do
      not Code.ensure_loaded?(Req) ->
        {:error, "req is missing — add {:req, \"~> 0.5\"} to use the Elks backend"}

      blank?(config[:username]) or blank?(config[:password]) ->
        {:error, "46elks is not configured (username/password missing)"}

      true ->
        {:ok, Keyword.put_new(config, :from, "Notify")}
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
