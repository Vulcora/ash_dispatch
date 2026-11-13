defmodule AshDispatch.Tenancy.Cron do
  @moduledoc """
  How a scheduled worker that works across every receipt runs when the receipts
  are in one schema per tenant.

  Two of them do: `AshDispatch.Workers.RetryFailedDeliveries` and
  `AshDispatch.Workers.ScrubSensitiveContent`. "Every failed receipt" and
  "every sensitive body older than a day" are questions per schema, and the
  library cannot know what the schemas are — the host says, through
  `AshDispatch.Tenants`.

  The entry job in the crontab therefore does no work itself: it reads the list
  of tenants and enqueues one job per tenant. That is deliberate, and it is the
  answer to "one tenant's failure must not stop the others":

  - a tenant whose pass raises fails **its own** job, which Oban reports and
    retries on its own terms, while the other tenants' jobs run;
  - the work spreads across the queue instead of one long-running job holding a
    worker for as many minutes as the host has tenants;
  - the crontab entry does not change, so the installer's configuration and
    every host's existing cron stay exactly as they are.

  A host whose receipts are **not** per tenant never sees any of this: the plan
  is one pass with no tenant, which is the pass the worker has always made.
  """

  alias AshDispatch.Tenancy
  alias AshDispatch.Tenants

  require Logger

  @typedoc """
  - `{:run, nil}` — one pass over one table, as before 0.9.4.
  - `{:run, tenant}` — one pass in this tenant; a job the fan-out enqueued.
  - `{:fan_out, tenants}` — enqueue one job per tenant and do nothing else.
  - `:no_tenants` — receipts are per tenant and the host has not said which
    tenants exist. Nothing can be done, and saying so is the only useful act.
  """
  @type plan :: {:run, term()} | {:fan_out, [term()]} | :no_tenants

  @doc "What this run of a cross-tenant worker should do. See `t:plan/0`."
  @spec plan(map()) :: plan()
  def plan(args) do
    cond do
      tenant = args["tenant"] || args[:tenant] ->
        case Tenants.check(tenant) do
          :ok ->
            {:run, tenant}

          {:error, :unknown_tenant} ->
            :no_tenants

          # `:tenants` was configured when the fan-out wrote this job's args
          # and is not now. The value is the library's own, from the host's own
          # `all/0`, so it is allowed through for the same reason a send job's
          # is — but it used to go through in silence, and it reaches the
          # scrub's raw `prefix:`.
          {:error, :not_configured} ->
            Tenants.warn_if_missing("A fanned-out cron job carries a tenant")
            {:run, tenant}
        end

      not Tenancy.receipts_per_tenant?() ->
        {:run, nil}

      true ->
        case Tenants.all() do
          [] -> :no_tenants
          tenants -> {:fan_out, tenants}
        end
    end
  end

  @doc """
  Enqueues one job of `worker` per tenant, at most one per tenant at a time.

  A tenant whose job cannot be enqueued is logged and the rest go on: the whole
  point of the fan-out is that one tenant cannot take the others down with it.

  `:ok`, or `{:error, reason}` when nothing could be enqueued and something
  tried. A run that did nothing used to answer `:ok` and be recorded by Oban
  as a success — the failure mode `no_tenants/1` is explicitly written to
  avoid, arrived at by another road.
  """
  @spec fan_out(module(), [term()]) :: :ok | {:error, String.t()}
  def fan_out(worker, tenants) do
    {enqueued, failed} =
      Enum.reduce(tenants, {0, 0}, fn tenant, {ok, bad} ->
        case enqueue(worker, tenant) do
          :ok ->
            {ok + 1, bad}

          {:error, reason} ->
            Logger.error(
              "#{inspect(worker)}: could not enqueue the pass for tenant " <>
                "#{inspect(tenant)}: #{inspect(reason)}"
            )

            {ok, bad + 1}
        end
      end)

    report(worker, enqueued, failed)
  end

  # One line a tick was noise on the happy path; it says something only when
  # something is wrong, and `debug` otherwise.
  defp report(worker, enqueued, 0) do
    Logger.debug("#{inspect(worker)}: #{enqueued} tenant passes enqueued")
    :ok
  end

  defp report(worker, 0, failed) do
    reason = "#{inspect(worker)}: not one of #{failed} tenant passes could be enqueued"
    Logger.error(reason)
    {:error, reason}
  end

  defp report(worker, enqueued, failed) do
    Logger.warning(
      "#{inspect(worker)}: #{enqueued} tenant passes enqueued, #{failed} could not be"
    )

    :ok
  end

  @doc """
  Says, once per VM, that the host's receipts are per tenant and nothing can be
  done about them until `:tenants` is configured.

  Not an error return: a cron job that fails every five minutes for a
  configuration reason is noise that buries the line that explains it.
  """
  @spec no_tenants(module()) :: :ok
  def no_tenants(worker) do
    Tenants.warn_if_missing(inspect(worker))
    :ok
  end

  # One pass per tenant in flight, which is what the design document promised
  # the fan-out would give ("Oban's `unique` keeps a slow tenant from being
  # enqueued twice") and what neither worker nor this call actually declared.
  # Without it every tick added one more pass per tenant whatever was still
  # queued — with the installer's retry entry and a few hundred tenants, a few
  # hundred jobs a minute — and two passes over one tenant could run at once.
  # `RetryFailedDeliveries` has `max_attempts: 1` and reads, transitions and
  # re-enqueues receipts with no lock of its own.
  #
  # Declared here rather than on the worker on purpose: `Oban.Plugins.Cron`
  # inserts the crontab ENTRY job itself, and a `unique` on the worker would
  # apply to that insert too — one with `keys: [:tenant]` against an entry
  # job whose args are `%{}` could hold the entry job back across ticks, for
  # every host, tenants or not.
  @unique [
    period: :infinity,
    keys: [:tenant],
    states: [:available, :scheduled, :executing, :retryable]
  ]

  @doc """
  The job the fan-out enqueues for one tenant, as an `Ecto.Changeset`.

  Public so the uniqueness can be asserted on the thing that is actually
  inserted, rather than on a changeset a test built the same way by hand.
  """
  @spec job(module(), term()) :: Ecto.Changeset.t()
  def job(worker, tenant) do
    worker.new(%{"tenant" => Tenancy.receipt_prefix(tenant)}, unique: @unique)
  end

  defp enqueue(worker, tenant) do
    case worker |> job(tenant) |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end
end
