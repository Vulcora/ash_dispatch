defmodule AshDispatch.Preparations.LoadObanJob do
  @moduledoc """
  Preparation that loads Oban job data for delivery receipts.

  Adds an `oban_job` field to each receipt containing:
  - state: Job state (available, scheduled, executing, completed, etc.)
  - queue: Queue name
  - worker: Worker module
  - scheduled_at: When the job is scheduled to run
  - attempted_at: When the job was last attempted
  - completed_at: When the job completed
  - errors: Array of error maps
  - attempt: Current attempt number
  - max_attempts: Maximum number of attempts
  """
  use Ash.Resource.Preparation
  import Ecto.Query

  @impl true
  def prepare(query, _opts, _context) do
    Ash.Query.after_action(query, fn _query, results ->
      # Get all receipt IDs that have oban_job_id
      # Filter out NotLoaded values
      job_ids =
        results
        |> Enum.filter(fn receipt ->
          case receipt.oban_job_id do
            %Ash.NotLoaded{} -> false
            nil -> false
            _ -> true
          end
        end)
        |> Enum.map(& &1.oban_job_id)
        |> Enum.uniq()

      if Enum.empty?(job_ids) do
        # No jobs to load, return results as-is
        {:ok, results}
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

        # Add oban_job to each receipt
        results_with_jobs =
          Enum.map(results, fn receipt ->
            case receipt.oban_job_id do
              %Ash.NotLoaded{} ->
                # oban_job_id not loaded, set oban_job to nil
                %{receipt | oban_job: nil}

              nil ->
                %{receipt | oban_job: nil}

              job_id ->
                oban_job = Map.get(jobs, job_id)
                %{receipt | oban_job: oban_job}
            end
          end)

        {:ok, results_with_jobs}
      end
    end)
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
