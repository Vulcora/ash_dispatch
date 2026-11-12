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
          {:error, :unknown_tenant} -> :no_tenants
          _ok_or_not_configured -> {:run, tenant}
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
  Enqueues one job of `worker` per tenant.

  A tenant whose job cannot be enqueued is logged and the rest go on: the whole
  point of the fan-out is that one tenant cannot take the others down with it.
  """
  @spec fan_out(module(), [term()]) :: :ok
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

    Logger.info(
      "#{inspect(worker)}: #{enqueued} tenant passes enqueued" <>
        if(failed > 0, do: ", #{failed} could not be", else: "")
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

  defp enqueue(worker, tenant) do
    case %{"tenant" => Tenancy.key(tenant)} |> worker.new() |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end
end
