defmodule AshDispatch.SMSBackend do
  @moduledoc """
  The behaviour an SMS backend implements.

      config :ash_dispatch, :sms_backend, MyApp.SMS

  `AshDispatch.SMSBackend.Elks` ships with the library and covers 46elks; this
  behaviour is for every other provider.

  ## Where it is called from

  From `AshDispatch.Workers.SendSMS`, not from the transport. The transport
  enqueues a job and marks the receipt `:scheduled`; the worker marks
  `:sending` and calls `deliver/4`. A backend therefore does not have to worry
  about holding a database transaction open — but it must not assume it runs
  synchronously with the action that triggered the event either.

  Requires an Oban queue named `:sms`.

  The job carries only the receipt id, so the context the worker passes is
  reconstructed from the receipt: `event_id` and `audience` are real, but
  `data` and `variables` are empty. A backend that needs either should read
  `receipt.content`, which was frozen when the receipt was created and
  therefore survives a retry.

  ## The contract

  - Read `receipt.recipient` (the phone number) and the message body from
    `receipt.content`. Use `AshDispatch.ContentMap.get_content/2`: the column
    is JSONB, so a freshly built struct carries atom keys while one read back
    from Postgres carries string keys. The dispatcher writes `:message`.
  - Send through the provider's API.
  - **Mark the receipt yourself.** The backend is what knows which failures are
    permanent:
    - delivered: `ReceiptStatus.mark_sent(receipt, %{"id" => provider_id})`
    - worth retrying: `ReceiptStatus.mark_failed(receipt, reason)`
    - never going to work: `ReceiptStatus.mark_failed_permanent(receipt, reason)`
  - Return `{:ok, updated_receipt}` or `{:error, reason}`.

  An `{:error, _}` makes the worker mark `:failed` and lets Oban retry. A
  malformed phone number or bad credentials belong in `mark_failed_permanent`
  — five retries will not fix them, and while they sit as `:failed` they only
  delay telling the person who can.

  ## The recipient field

  Without an `:sms` entry in `recipient_fields`, **every** recipient raises
  `"No identifier field configured for sms transport"`, and the error does not
  say where to look:

      config :ash_dispatch,
        recipient_fields: [
          sms: [identifier: :phone, name: [:display_name, :name]]
        ]
  """

  @callback deliver(
              receipt :: struct(),
              context :: AshDispatch.Context.t(),
              channel :: AshDispatch.Channel.t(),
              event_config :: map()
            ) :: {:ok, struct()} | {:error, term()}
end
