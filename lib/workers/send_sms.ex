defmodule AshDispatch.Workers.SendSMS do
  @moduledoc """
  Sends one SMS receipt through the configured backend.

  Mirrors `AshDispatch.Workers.SendEmail`, for the same reason: dispatch runs
  in an `after_action` hook **inside the action's transaction**, and an
  outbound HTTPS round trip per recipient does not belong there. The transport
  enqueues, the worker sends.

  Before 0.8.2 the SMS transport called the backend directly. A slow or
  unreachable provider held the action's transaction open, `time:` scheduling
  could not be used, and a failed send could never be retried —
  `RetryFailedDeliveries` only recognises transports that have a worker.

  ## Job arguments

  - `receipt_id` — the receipt's UUID. Everything else is read from the
    receipt, so a retry can never send different text than the one frozen at
    creation.
  """

  use Oban.Worker,
    queue: :sms,
    max_attempts: 5,
    # One job per receipt. A "send now" while the original is still queued must
    # not become two messages to the same phone.
    unique: [keys: [:receipt_id], states: [:available, :scheduled, :executing]]

  alias AshDispatch.Config
  alias AshDispatch.ReceiptStatus

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    receipt_id = args["receipt_id"]

    case Config.delivery_receipt_resource() |> Ash.get(receipt_id, authorize?: false) do
      {:ok, receipt} ->
        process_sms(receipt)

      {:error, error} ->
        Logger.error("Failed to fetch receipt #{receipt_id}: #{inspect(error)}")
        {:error, :receipt_not_found}
    end
  end

  @doc false
  # Builds a fresh job for a receipt. Used by the retry path, which has no
  # other arguments to carry — the text lives in the receipt.
  def new_for_receipt(receipt), do: new(%{receipt_id: receipt.id})

  defp process_sms(receipt) do
    # Terminal state: a duplicate job should finish as success, not as a second
    # message. Same early exit as SendEmail.
    if receipt.status in [:sent, :skipped, :failed_permanent] do
      Logger.info(
        "Receipt #{receipt.id} already in terminal state #{receipt.status}, job completing as success"
      )

      :ok
    else
      case backend() do
        nil ->
          ReceiptStatus.mark_skipped(receipt, "transport_not_implemented")
          :ok

        backend ->
          send_with(backend, receipt)
      end
    end
  end

  defp send_with(backend, receipt) do
    case ReceiptStatus.mark_sending(receipt) do
      {:ok, receipt} ->
        deliver(backend, receipt)

      {:error, %Ash.Error.Invalid{errors: errors}} ->
        # Another job got there first. Same reasoning as SendEmail: a race over
        # one receipt is not an error, it is a duplicate.
        if Enum.any?(errors, &match?(%AshStateMachine.Errors.NoMatchingTransition{}, &1)) do
          Logger.info(
            "Receipt #{receipt.id} state transition conflict (likely duplicate job), completing as success"
          )

          :ok
        else
          Logger.error("Receipt #{receipt.id} update failed: #{inspect(errors)}")
          {:error, errors}
        end

      {:error, reason} ->
        Logger.error("Receipt #{receipt.id} mark_sending failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # The backend owns its own receipt: it knows which failures are permanent
  # (malformed number, bad credentials) and which are worth retrying, so it
  # marks the receipt itself. Here we only translate the outcome for Oban.
  defp deliver(backend, receipt) do
    case backend.deliver(receipt, context_for(receipt), channel_for(receipt), %{}) do
      {:ok, %{status: status} = updated} when status in [:sent, :skipped, :failed_permanent] ->
        Logger.info("SMS #{status} for receipt #{updated.id}")
        :ok

      {:ok, %{status: :failed} = updated} ->
        # Oban will retry; the receipt already carries the error.
        {:error, updated.error_message || "sms_failed"}

      {:ok, _other} ->
        :ok

      {:error, reason} ->
        # The backend never got to mark it — do it here, or the receipt strands
        # in :sending until the stranded-receipt cron picks it up.
        ReceiptStatus.mark_failed(receipt, reason)
        Logger.error("SMS failed for receipt #{receipt.id}: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    error ->
      ReceiptStatus.mark_failed(receipt, error)
      Logger.error("SMS backend raised for receipt #{receipt.id}: #{inspect(error)}")
      {:error, error}
  end

  # The job carries only the receipt id, so the original context is gone — it
  # holds arbitrary data and does not survive a JSONB round trip. The backend
  # therefore gets a context reconstructed from what the receipt can answer.
  # `data` and `variables` are EMPTY here; a backend that needs them should
  # read `receipt.content`, which is frozen at creation and survives a retry
  # for exactly that reason.
  defp context_for(receipt) do
    %AshDispatch.Context{event_id: receipt.event_id, data: %{}, variables: %{}}
  end

  defp channel_for(receipt) do
    %AshDispatch.Channel{transport: :sms, audience: Map.get(receipt, :audience)}
  end

  defp backend, do: Config.sms_backend()
end
