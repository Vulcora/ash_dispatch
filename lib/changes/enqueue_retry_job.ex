defmodule AshDispatch.Changes.EnqueueRetryJob do
  @moduledoc """
  Enqueues a new Oban job when a delivery receipt is retried.

  This change ensures that when a user manually retries a failed delivery,
  a new Oban job is created to process it.
  """
  use Ash.Resource.Change

  alias AshDispatch.Workers.SendEmail

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, receipt ->
      case enqueue_job(receipt) do
        {:ok, job} ->
          Logger.info("EnqueueRetryJob: Created Oban job #{job.id} for receipt #{receipt.id}")

          # Update the receipt with the new job ID
          {:ok, %{receipt | oban_job_id: job.id}}

        {:error, reason} ->
          Logger.error(
            "EnqueueRetryJob: Failed to enqueue job for receipt #{receipt.id}: #{inspect(reason)}"
          )

          # Still return ok - the receipt was updated, job just failed
          {:ok, receipt}
      end
    end)
  end

  defp enqueue_job(%{transport: :email} = receipt) do
    %{receipt_id: receipt.id}
    |> SendEmail.new()
    |> Oban.insert()
  end

  defp enqueue_job(%{transport: transport} = receipt) do
    Logger.warning(
      "EnqueueRetryJob: Retry not implemented for transport #{transport}, receipt_id=#{receipt.id}"
    )

    {:error, :transport_not_supported}
  end
end
