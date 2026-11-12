defmodule AshDispatch.Tenancy.Job do
  @moduledoc """
  The tenant on its way into and out of an Oban job.

  A send job carries a receipt id and nothing else that matters, so when
  receipts live in one schema per tenant the job has to say which schema — and
  that makes the job args the one place a tenant reaches the library from
  storage rather than from a running dispatch. It is therefore also the one
  place where a tenant has to be held against what the host recognises before
  it is used: a tenant is a Postgres schema name.

  All three send workers open the same way:

      case AshDispatch.Tenancy.Job.receipt(args) do
        {:ok, receipt} -> ...
        {:cancel, reason} -> {:cancel, reason}
        {:error, _} -> {:error, :receipt_not_found}
      end

  ## What fails closed

  - **A tenant the host does not recognise** — the job is cancelled. Retrying
    it would read the same unrecognised schema name five more times, and it is
    the one input here an attacker with write access to `oban_jobs` could have
    chosen.
  - **A tenant whose schema does not exist** — cancelled too, for the same
    reason: Postgres will not grow the schema on the second attempt.
  - **A receipt that is not in that tenant** — `{:error, :receipt_not_found}`,
    which is what a job for tenant A edited to say tenant B produces: the id
    exists in A's schema and nowhere else. Nothing is sent, and the receipt in
    A is untouched.
  """

  alias AshDispatch.Config
  alias AshDispatch.Tenancy

  require Logger

  @doc """
  The receipt a job is about, read in the tenant the job names and remembering
  which one that was.

  `{:ok, receipt}`, `{:cancel, reason}` for something no retry will fix, or
  `{:error, reason}` for everything else (Oban retries).
  """
  @spec receipt(map()) :: {:ok, struct()} | {:cancel, String.t()} | {:error, term()}
  def receipt(args) do
    receipt_id = args["receipt_id"]
    resource = Config.delivery_receipt_resource()

    case Tenancy.from_job_args(args) do
      {:ok, tenant} ->
        fetch(resource, receipt_id, tenant)

      {:error, reason} ->
        Logger.error(
          "AshDispatch: refusing a send job for receipt #{inspect(receipt_id)}: #{reason}. " <>
            "A tenant is a schema name, so an unrecognised one is never read from."
        )

        {:cancel, reason}
    end
  end

  @doc """
  Puts the tenant a receipt was read in into job args, under `"tenant"`.

  Nothing is added for a receipt that carries none, so a retry of a job from
  before 0.9.4 — or any job of a host without tenants — has the args it always
  had.
  """
  @spec put_tenant(map(), struct()) :: map()
  def put_tenant(args, receipt) do
    case Tenancy.key(Tenancy.of(receipt)) do
      nil -> args
      tenant -> Map.put(args, "tenant", tenant)
    end
  end

  defp fetch(resource, receipt_id, tenant) do
    case Ash.get(resource, receipt_id, [authorize?: false] ++ Tenancy.opts(resource, tenant)) do
      {:ok, receipt} -> {:ok, Tenancy.remember(receipt, tenant)}
      {:error, error} -> classify(error, tenant)
    end
  rescue
    error ->
      case classify(error, tenant) do
        {:cancel, reason} -> {:cancel, reason}
        _other -> reraise(error, __STACKTRACE__)
      end
  end

  # "There is nothing there to read" is only read as a missing tenant schema
  # when a tenant was actually named. For a host without tenants a missing
  # table is a deploy that went wrong, and Oban retrying it is the behaviour
  # that release had.
  defp classify(error, tenant) do
    if not is_nil(tenant) and Tenancy.missing_schema?(error) do
      {:cancel, "tenant #{inspect(tenant)} has no schema to read the receipt from"}
    else
      {:error, error}
    end
  end
end
