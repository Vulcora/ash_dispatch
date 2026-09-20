defmodule AshDispatch.Changes.EnqueueRetryJob do
  @moduledoc """
  Enqueues a new Oban job when a delivery receipt is retried.

  This change ensures that when a user manually retries a failed delivery,
  a new Oban job is created to process it.
  """
  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, receipt ->
      case enqueue_job(receipt) do
        {:ok, %{id: job_id}} when is_integer(job_id) ->
          Logger.info("EnqueueRetryJob: Created Oban job #{job_id} for receipt #{receipt.id}")

          # Persist the new job ID to the database
          receipt
          |> Ash.Changeset.for_update(:update, %{oban_job_id: job_id}, authorize?: false)
          |> Ash.update(authorize?: false)

        {:ok, _direct} ->
          # Direct retry (e.g. in_app) — no Oban job created
          Logger.info("EnqueueRetryJob: Direct retry for receipt #{receipt.id}")
          {:ok, receipt}

        {:error, reason} ->
          Logger.error(
            "EnqueueRetryJob: Failed to enqueue job for receipt #{receipt.id}: #{inspect(reason)}"
          )

          # Still return ok - the receipt was updated, job just failed
          {:ok, receipt}
      end
    end)
  end

  # Vilken transport som går att göra om, och hur, bor i
  # AshDispatch.Transport.Retry — samma lista som cronen i
  # Workers.RetryFailedDeliveries använder. Två kopior av den listan betydde
  # att en transport kunde få omförsök från cronen men inte från knapparna.
  defp enqueue_job(%{transport: transport} = receipt) do
    case AshDispatch.Transport.Retry.strategy(transport) do
      {:worker, _} ->
        AshDispatch.Transport.Retry.enqueue_worker(receipt)

      {:direct, modul} ->
        # Synkron leverans — görs om direkt. Knappen vill ha ett "jobb" att
        # rapportera, till skillnad från cronen som vill veta att kvittot
        # redan är färdighanterat.
        case modul.retry_from_receipt(receipt) do
          :ok -> {:ok, %{id: :direct_retry}}
          error -> error
        end

      :unsupported ->
        Logger.warning(
          "EnqueueRetryJob: Retry not implemented for transport #{transport}, receipt_id=#{receipt.id}"
        )

        {:error, :transport_not_supported}
    end
  end
end
