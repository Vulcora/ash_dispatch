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

  # Which transports can be retried, and how, lives in
  # AshDispatch.Transport.Retry — the same list the cron in
  # Workers.RetryFailedDeliveries uses. Two copies of that list meant a
  # transport could be retried by the cron but not by these actions.
  defp enqueue_job(%{transport: transport} = receipt) do
    case AshDispatch.Transport.Retry.strategy(transport) do
      {:worker, _} ->
        AshDispatch.Transport.Retry.enqueue_worker(receipt)

      {:direct, module} ->
        # Synchronous delivery — retried inline. The action wants a "job" to
        # report back, unlike the cron, which wants to know the receipt is
        # already fully handled.
        case module.retry_from_receipt(receipt) do
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
