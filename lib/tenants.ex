defmodule AshDispatch.Tenants do
  @moduledoc """
  Which tenants exist — the one question the library cannot answer for itself.

  Two jobs in the library have to work across every tenant rather than inside
  one: `AshDispatch.Workers.RetryFailedDeliveries` and
  `AshDispatch.Workers.ScrubSensitiveContent`. When receipts live in one schema
  per tenant, "every failed receipt" is a question per schema, and the library
  has no way to know what the schemas are. Tenants might be rows in a table, a
  list in config, an organisation resource with a filter on it, or something
  only the host would recognise.

  So the host says:

      config :ash_dispatch, tenants: MyApp.Tenants

      defmodule MyApp.Tenants do
        @behaviour AshDispatch.Tenants

        @impl true
        def all do
          MyApp.Accounts.Organisation
          |> Ash.Query.filter(active == true)
          |> Ash.read!(authorize?: false)
          |> Enum.map(& &1.schema)
        end
      end

  `{module, function}`, `{module, function, args}` and a zero-argument function
  are accepted too, for a host whose list is one expression long.

  ## `known?/1`

  A tenant can also arrive from **outside**: in the tag a provider echoes back
  on a webhook, or in the args of an Oban job. A tenant is a Postgres schema
  name, so a string that reaches a query unchecked chooses which schema is
  read. Nothing in this library ever lets an outside tenant through without
  asking:

      @impl true
      def known?(tenant), do: tenant in all()

  The callback is optional; without it, membership in `all/0` is the answer,
  which is correct and costs a list. Implement it when `all/0` is expensive
  enough that you would rather answer with one query.

  ## Without it

  `all/0` answers `[]` and `check/1` answers `{:error, :not_configured}`. A
  host whose receipts are **not** per tenant never needs this module: the cron
  workers read one table, as they always have. A host whose receipts **are**
  per tenant is warned once per VM, because without this the retries and the
  scrub quietly do nothing.
  """

  require Logger

  @doc "Every tenant the library should work across."
  @callback all() :: [term()]

  @doc """
  Whether `tenant` is one of yours. Optional; the default is membership in
  `c:all/0`.
  """
  @callback known?(tenant :: term()) :: boolean()

  @optional_callbacks known?: 1

  @doc """
  The configured list of tenants, or `[]` when nothing is configured.

  A list that cannot be read is logged and answered as `[]` — a cron worker
  that cannot ask must not take the whole run down with it.
  """
  @spec all() :: [term()]
  def all do
    case AshDispatch.Config.tenants() do
      nil -> []
      source -> listed(source)
    end
  rescue
    error ->
      Logger.error(
        "ash_dispatch: :tenants could not be read (#{Exception.message(error)}); " <>
          "treating it as no tenants."
      )

      []
  end

  @doc "Whether the host has configured a source of tenants at all."
  @spec configured?() :: boolean()
  def configured?, do: not is_nil(AshDispatch.Config.tenants())

  @doc """
  Whether a tenant that arrived from outside may be used.

  - `:ok` — `nil` (there is no tenant to check), or the host recognises it.
  - `{:error, :unknown_tenant}` — the host does not recognise it. The caller
    must not touch the database with it: a tenant is a schema name.
  - `{:error, :not_configured}` — the host has not said what its tenants are,
    so the question cannot be answered. What the caller does then depends on
    where the tenant came from, and each caller says so where it decides.
  """
  @spec check(term()) :: :ok | {:error, :unknown_tenant | :not_configured}
  def check(nil), do: :ok

  def check(tenant) do
    case AshDispatch.Config.tenants() do
      nil ->
        {:error, :not_configured}

      source ->
        if ask_known?(source, tenant), do: :ok, else: {:error, :unknown_tenant}
    end
  rescue
    error ->
      Logger.error(
        "ash_dispatch: the :tenants check raised for #{inspect(tenant)} " <>
          "(#{Exception.message(error)}); the tenant is refused."
      )

      {:error, :unknown_tenant}
  end

  @doc """
  Warns once per VM when receipts are per tenant and no source of tenants is
  configured. Called by the cron workers and by the webhook handler, which are
  the three places it actually breaks something.
  """
  @spec warn_if_missing(String.t()) :: :ok
  def warn_if_missing(what) do
    if AshDispatch.Tenancy.receipts_per_tenant?() and not configured?() do
      if not :persistent_term.get({__MODULE__, :warned}, false) do
        :persistent_term.put({__MODULE__, :warned}, true)

        Logger.error("""
        ash_dispatch: your receipts are stored per tenant, but :tenants is not configured.

        #{what} works across tenants and cannot find them. Nothing is retried,
        nothing is scrubbed, and a provider webhook cannot name the tenant its
        receipt is in.

            config :ash_dispatch, tenants: MyApp.Tenants

        See AshDispatch.Tenants.
        """)
      end
    end

    :ok
  end

  defp ask(module) when is_atom(module), do: module.all()
  defp ask({module, function}), do: apply(module, function, [])
  defp ask({module, function, args}) when is_list(args), do: apply(module, function, args)
  defp ask(fun) when is_function(fun, 0), do: fun.()

  defp ask(other) do
    raise ArgumentError,
          ":tenants is #{inspect(other)}, which cannot be called. Expected a module " <>
            "implementing AshDispatch.Tenants, {module, function}, " <>
            "{module, function, args}, or a zero-argument function."
  end

  # The source `check/1` already read is passed in, so the host's list is asked
  # for at most once per check: `all/0` would read `:tenants` a second time to
  # find the same source. With `known?/1` the list is not asked for at all,
  # which is the whole reason that callback exists.
  defp ask_known?(module, tenant) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :known?, 1) do
      module.known?(tenant) == true
    else
      member?(tenant, listed(module))
    end
  end

  defp ask_known?(source, tenant), do: member?(tenant, listed(source))

  defp listed(source), do: source |> ask() |> List.wrap()

  # Compared as SCHEMA NAMES — `Ash.ToTenant` — so a host that answers with
  # structs and a tag that comes back as a string still agree, and the gate
  # approves exactly the strings that can be read.
  #
  # `AshDispatch.Context.tenant_key/1` was the comparison until 0.9.4-rc.1, and
  # for a host whose `all/0` answers with structs it reduced both sides to the
  # struct's `:id`: the gate then approved an id that is not a schema name, so
  # it was no protection at all. For a string tenant the two are the same
  # function.
  defp member?(tenant, tenants) do
    prefix = AshDispatch.Tenancy.receipt_prefix(tenant)
    Enum.any?(tenants, &(AshDispatch.Tenancy.receipt_prefix(&1) == prefix))
  end
end
