defmodule AshDispatch.Transports.SMS do
  use AshDispatch.Transport, atom: :sms, skip_receipt?: false

  @moduledoc """
  SMS transport — enqueues a job that calls the configured backend.

      config :ash_dispatch, :sms_backend, MyApp.SMS

  The module must implement `AshDispatch.SMSBackend`. Without one the receipt
  is marked `:skipped` with `error_message: "transport_not_implemented"`, as
  before.

  ## The path

  ```
  pending → scheduled (job enqueued)
          ↘ skipped   (recipient opted out)

  later, in AshDispatch.Workers.SendSMS:
  scheduled → sending → sent
                      ↘ failed  (retried)
  ```

  ## What changed

  The transport used to call `backend.deliver/4` **synchronously**. Dispatch
  runs in an `after_action` hook inside the action's transaction, so a slow
  provider held that transaction open, `time:` could not be used, and a failed
  message could never be retried — `RetryFailedDeliveries` only recognises
  transports that have a worker.

  It now takes the same shape as email: consent, enqueue, `:scheduled`. A
  backend that already sends synchronously keeps working unchanged — it is
  simply called from the worker rather than from the transaction.

  Requires an Oban queue named `:sms`.

  ## Delayed delivery

  Falls out of the queue, exactly as it does for email:

      channel = %Channel{transport: :sms, time: {:in, 300}}
      channel = %Channel{transport: :sms, time: {:at, ~U[2026-09-21 06:00:00Z]}}

  ## The recipient field

  `config :ash_dispatch, :recipient_fields` **must** carry an `:sms` entry, or
  every recipient raises `"No identifier field configured for sms
  transport"`:

      recipient_fields: [
        sms: [identifier: :phone, name: [:display_name, :name]]
      ]
  """

  require Logger

  alias AshDispatch.Transports.Email
  alias AshDispatch.Transports.Preferences

  def deliver(receipt, context, channel, event_config) do
    Preferences.with_consent(receipt, context, channel, event_config, fn ->
      do_deliver(receipt, context, channel)
    end)
  end

  # The consent gate sits above the queue deliberately: a receipt the recipient
  # opted out of should never become a job.
  defp do_deliver(receipt, context, channel) do
    case AshDispatch.Config.sms_backend() do
      nil ->
        Logger.info("SMS transport not yet implemented (no :sms_backend configured), skipping")

        receipt
        |> Ash.Changeset.for_update(:skip, %{error_message: "transport_not_implemented"})
        |> Ash.update!(authorize?: false)
        |> then(&{:ok, &1})

      _backend ->
        result = enqueue(receipt, channel)
        {:ok, update_receipt_with_job(receipt, result)}
    end
  rescue
    error ->
      Logger.error("""
      SMS transport failed to enqueue job
      Event: #{context.event_id}
      Error: #{inspect(error)}
      """)

      {:error, error}
  end

  defp enqueue(receipt, channel) do
    # The receipt id only. The body and the recipient live in the receipt, and
    # that is the point: a retry must never be able to send anything other than
    # what was frozen at creation.
    changeset =
      AshDispatch.Workers.SendSMS.new(%{"receipt_id" => receipt.id},
        schedule_in: Email.schedule_seconds(channel)
      )

    case Oban.insert(changeset) do
      {:ok, job} ->
        Logger.debug("Enqueued SMS job #{job.id} for receipt #{receipt.id}")
        {:ok, job}

      {:error, error} ->
        Logger.error("Failed to enqueue SMS job: #{inspect(error)}")
        {:error, error}
    end
  end

  defp update_receipt_with_job(receipt, {:ok, job}) do
    # Re-read: under Oban's inline mode the worker has already finished and the
    # receipt is no longer :pending.
    case Ash.get(receipt.__struct__, receipt.id, authorize?: false) do
      {:ok, %{status: :pending} = current} ->
        current
        |> Ash.Changeset.for_update(:schedule, %{oban_job_id: job.id})
        |> Ash.update!(authorize?: false)

      {:ok, current} ->
        Logger.debug(
          "Receipt #{receipt.id} already in #{current.status} state, skipping schedule"
        )

        current

      {:error, _} ->
        receipt
    end
  end

  defp update_receipt_with_job(receipt, {:error, reason}) do
    receipt
    |> Ash.Changeset.for_update(:mark_failed, %{error_message: inspect(reason)})
    |> Ash.update!(authorize?: false)
  end
end
