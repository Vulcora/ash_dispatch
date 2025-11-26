defmodule AshDispatch.Calculations.ObanJob do
  @moduledoc """
  Calculation that loads Oban job data for delivery receipts.

  This is populated by the LoadObanJob preparation during queries.
  The calculation itself just returns nil - the real loading happens in the preparation.
  """
  use Ash.Resource.Calculation
  import Ecto.Query

  @impl true
  def calculate(records, _opts, _context) do
    # Get all receipt IDs that have oban_job_id
    job_ids =
      records
      |> Enum.filter(fn receipt -> receipt.oban_job_id end)
      |> Enum.map(& &1.oban_job_id)
      |> Enum.uniq()

    if Enum.empty?(job_ids) do
      # No jobs to load, return nil for all
      Enum.map(records, fn _ -> nil end)
    else
      # Query Oban jobs using configured repo
      repo = get_repo()

      jobs =
        from(j in Oban.Job,
          where: j.id in ^job_ids,
          select: %{
            id: j.id,
            state: j.state,
            queue: j.queue,
            worker: j.worker,
            scheduled_at: j.scheduled_at,
            attempted_at: j.attempted_at,
            completed_at: j.completed_at,
            errors: j.errors,
            attempt: j.attempt,
            max_attempts: j.max_attempts
          }
        )
        |> repo.all()
        |> Map.new(&{&1.id, &1})

      # Return oban_job for each receipt
      Enum.map(records, fn receipt ->
        if receipt.oban_job_id do
          Map.get(jobs, receipt.oban_job_id)
        else
          nil
        end
      end)
    end
  end

  @impl true
  def load(_query, _opts, _context) do
    # Load oban_job_id so we can use it in calculate/3
    [:oban_job_id]
  end

  defp get_repo do
    Application.get_env(:ash_dispatch, :repo) ||
      raise """
      Missing configuration for :ash_dispatch, :repo

      Add to your config:

          config :ash_dispatch,
            repo: MyApp.Repo
      """
  end
end
