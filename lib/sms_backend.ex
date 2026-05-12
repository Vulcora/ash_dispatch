defmodule AshDispatch.SMSBackend do
  @moduledoc """
  Behaviour that an SMS backend module implements. Configure a backend
  in your app config:

      config :ash_dispatch, :sms_backend, MyApp.SMS

  The transport (`AshDispatch.Transports.SMS`) will call your backend's
  `deliver/4` whenever an event channel with `transport: :sms` fires.

  ## Implementation contract

  - Read `receipt.recipient` (phone number — your responsibility to
    validate format) and `receipt.content[:body]`/`:message` for the
    SMS body.
  - Send the SMS via your provider's API.
  - Update the receipt via Ash:
    - On success: `for_update(:mark_sent, %{provider_id: provider_id})`
    - On failure: `for_update(:mark_failed, %{error_message: reason})`
  - Return `{:ok, updated_receipt}` or `{:error, reason}`.

  Most backends are thin wrappers around HTTP clients (Twilio, Vonage,
  Telavox SMS, etc.).
  """

  @callback deliver(
              receipt :: struct(),
              context :: AshDispatch.Context.t(),
              channel :: AshDispatch.Channel.t(),
              event_config :: map()
            ) :: {:ok, struct()} | {:error, term()}
end
