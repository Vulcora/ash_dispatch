defmodule AshDispatch.Changes.CancelJob do
  @moduledoc false
  # After a receipt is cancelled (`:cancel`), its Oban job is cancelled too, so
  # it never runs. The send workers already stop on a terminal receipt, so a job
  # that slips through sends nothing; cancelling it keeps the queue honest, so
  # the job is not counted as coming. A receipt without a job, or an Oban that
  # cannot be reached, only logs: the receipt is :skipped either way, which is
  # what stops the mail.
  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, receipt ->
      cancel(Map.get(receipt, :oban_job_id))
      {:ok, receipt}
    end)
  end

  defp cancel(nil), do: :ok

  defp cancel(job_id) do
    Oban.cancel_job(job_id)
  rescue
    error ->
      Logger.warning(
        "AshDispatch: receipt cancelled, but its job #{job_id} could not be cancelled: " <>
          Exception.message(error)
      )

      :ok
  end
end
