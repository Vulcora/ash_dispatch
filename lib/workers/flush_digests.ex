defmodule AshDispatch.Workers.FlushDigests do
  @moduledoc """
  Sends a recipient's digest when its window is due. See `AshDispatch.Digest`.

  Two kinds of job:

    * **one recipient, one window** — `%{"recipient" => …, "window" => …}`,
      scheduled by `AshDispatch.Digest` when an email is batched, for the time
      the window is due. A newer email for the same recipient and window moves
      the scheduled job instead of adding one (`replace: [scheduled:
      [:scheduled_at]]`). A job that runs early — Oban ran it, the clock moved
      — snoozes until the window is due.
    * **a sweep** — no recipient: every group that is due is sent. The retry
      pass (`AshDispatch.Workers.RetryFailedDeliveries`) already sweeps on
      every run, so a host needs no cron entry for this; one that wants a
      tighter bound than its retry interval can schedule this worker on its
      own, and it fans out per tenant like the other cross-tenant workers.

  The queue is `config :ash_dispatch, digest_queue:` (default `:emails`).
  """

  use Oban.Worker,
    queue: :emails,
    max_attempts: 5,
    unique: [
      keys: [:recipient, :window, :tenant],
      states: [:scheduled, :available, :retryable]
    ]

  alias AshDispatch.Config
  alias AshDispatch.Digest
  alias AshDispatch.Tenancy

  require Logger

  @impl Oban.Worker
  def __opts__ do
    Keyword.put(super(), :queue, Config.digest_queue())
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"recipient" => recipient, "window" => window} = args}) do
    case Tenancy.from_job_args(args) do
      {:ok, tenant} ->
        Digest.flush(recipient, window, tenant)

      {:error, reason} ->
        Logger.warning("AshDispatch: refusing a digest flush job: #{reason}")
        {:cancel, reason}
    end
  end

  def perform(%Oban.Job{args: args}) do
    case Tenancy.Cron.plan(args) do
      {:run, tenant} -> Digest.sweep(tenant)
      {:fan_out, tenants} -> Tenancy.Cron.fan_out(__MODULE__, tenants)
      :no_tenants -> Tenancy.Cron.no_tenants(__MODULE__)
    end
  end

  @doc false
  # The flush job for one recipient and window, scheduled for `due`. Public so
  # what is inserted can be asserted on, rather than a changeset a test built
  # the same way by hand.
  @spec job(String.t(), String.t(), String.t() | nil, DateTime.t()) :: Ecto.Changeset.t()
  def job(recipient, window_key, tenant_prefix, %DateTime{} = due) do
    %{"recipient" => recipient, "window" => window_key}
    |> then(fn args ->
      if tenant_prefix, do: Map.put(args, "tenant", tenant_prefix), else: args
    end)
    |> new(scheduled_at: due, replace: [scheduled: [:scheduled_at]])
  end
end
