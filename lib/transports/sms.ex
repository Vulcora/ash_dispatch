defmodule AshDispatch.Transports.SMS do
  use AshDispatch.Transport, atom: :sms, skip_receipt?: false

  @moduledoc """
  SMS transport — delegates to a consumer-configured backend.

  Configure a backend module in your app config and ash_dispatch will
  call its `deliver/4` callback every time an event with an `:sms`
  channel fires:

      config :ash_dispatch, :sms_backend, MyApp.SMS

  The backend module must implement `AshDispatch.SMSBackend` —
  essentially one function:

      defmodule MyApp.SMS do
        @behaviour AshDispatch.SMSBackend

        @impl true
        def deliver(receipt, context, channel, event_config) do
          # send via Twilio/Telavox/etc.
          # then update the receipt: status :sent (success) or :failed.
          # return `{:ok, updated_receipt}` or `{:error, reason}`.
        end
      end

  When no backend is configured the receipt is marked `:skipped` with
  `error_message: "transport_not_implemented"` — same as the original
  stub. This preserves backwards-compat for consumers that haven't
  wired SMS yet.
  """

  require Logger

  alias AshDispatch.Config
  alias AshDispatch.Transports.Preferences

  def deliver(receipt, context, channel, event_config) do
    Preferences.with_consent(receipt, context, channel, event_config, fn ->
      leverera(receipt, context, channel, event_config)
    end)
  end

  # The gate sits ABOVE the backend on purpose: a consumer's own backend
  # cannot be expected to know about preferences, and asking it to would put
  # the same eight lines in every app that wires SMS.
  defp leverera(receipt, context, channel, event_config) do
    case Config.sms_backend() do
      nil ->
        Logger.info("SMS transport not yet implemented (no :sms_backend configured), skipping")

        receipt
        |> Ash.Changeset.for_update(:skip, %{error_message: "transport_not_implemented"})
        |> Ash.update!(authorize?: false)
        |> then(&{:ok, &1})

      backend when is_atom(backend) ->
        backend.deliver(receipt, context, channel, event_config)
    end
  end
end
