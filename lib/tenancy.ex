defmodule AshDispatch.Tenancy do
  @moduledoc """
  Whether a tenant is ever mentioned to Ash, and which one.

  The library knew what a tenant was from 0.8.8 and stored one from 0.9.0, but
  only ever as a value it passed along: every read and write it made, it made
  without one. For a host whose receipts and notifications live in the public
  schema that was fine. For a host with `multitenancy strategy :context` and
  one Postgres schema per tenant it was not — a receipt written during a
  tenant's action landed in `public`, and `ScrubSensitiveContent` never reached
  a tenant schema at all.

  0.9.4 carries the tenant through the whole flow. This module is the one place
  that decides whether to, and it is deliberately small, because it carries the
  whole compatibility story:

      Ash.get(resource, id, [authorize?: false] ++ Tenancy.opts(resource, tenant))

  `opts/2` returns `[]` for a resource that declares no multitenancy — which is
  what every host had before this release — so the call is the call that was
  made before, argument for argument. That is a property a test can hold the
  library to rather than a claim in a changelog, and
  `test/tenancy/compatibility_test.exs` does.

  It is the **resource** that decides, never the presence of a tenant: a host
  that passes `tenant:` to a resource without multitenancy is relying on Ash to
  ignore it, and a library should not rely on that.

  ## Which tenant

  `remember/2` and `of/1` carry a tenant on a record, in its metadata, so a
  receipt read with a tenant can be updated with the same one without every
  caller having to pass it again:

      receipt = Tenancy.remember(receipt, tenant)
      ...
      ReceiptStatus.mark_sent(receipt, response)   # goes to the same schema

  That is how `AshDispatch.ReceiptStatus` works: it takes the tenant from the
  struct it was handed. "The tenant came from the receipt we are updating" is
  then true by construction rather than by discipline, and the eight status
  transitions need no new arguments.
  """

  alias AshDispatch.Config
  alias AshDispatch.Context

  @metadata_key :ash_dispatch_tenant

  @doc """
  Whether `resource` stores its rows per tenant — i.e. declares any Ash
  `multitenancy` strategy.

  `false` for anything that is not an Ash resource, so a pseudo-receipt (the
  `:broadcast` and `:oban` transports get one) answers the same as a resource
  without multitenancy.
  """
  @spec multitenant?(term()) :: boolean()
  def multitenant?(resource) when is_atom(resource) and not is_nil(resource) do
    not is_nil(Ash.Resource.Info.multitenancy_strategy(resource))
  rescue
    _ -> false
  end

  def multitenant?(_resource), do: false

  @doc """
  `[tenant: tenant]` when `resource` is multitenant and `tenant` is not `nil`;
  `[]` otherwise.

  Append it to the options of every read and write the library makes.
  """
  @spec opts(term(), term()) :: keyword()
  def opts(resource, tenant)
  def opts(_resource, nil), do: []

  def opts(resource, tenant) do
    if multitenant?(resource), do: [tenant: tenant], else: []
  end

  @doc "Whether the configured delivery receipt resource stores receipts per tenant."
  @spec receipts_per_tenant?() :: boolean()
  def receipts_per_tenant?, do: multitenant?(Config.delivery_receipt_resource())

  @doc "Whether the configured notification resource stores notifications per tenant."
  @spec notifications_per_tenant?() :: boolean()
  def notifications_per_tenant?, do: multitenant?(Config.notification_resource())

  @doc "Whether the configured preference resource stores preferences per tenant."
  @spec preferences_per_tenant?() :: boolean()
  def preferences_per_tenant?, do: multitenant?(Config.preference_resource())

  @doc """
  The tenant as the library stores it in the `tenant` **column** —
  `AshDispatch.Context.tenant_key/1`.

  This is not a schema name. For a tenant that is a struct it is the struct's
  `:id`, which `Ash.ToTenant` is free to turn into something else entirely
  (`"org_" <> id`, `org.schema`). Use `prefix/2` for anything that becomes a
  schema name.
  """
  @spec key(term()) :: String.t() | nil
  def key(tenant), do: Context.tenant_key(tenant)

  @doc """
  The tenant as a **schema name**: what Ash itself would prefix `resource`'s
  table with, as a string.

  This is `Ash.ToTenant.to_tenant/2` — the protocol Ash applies on every read
  and write — and it is the only correct answer for a value the library has to
  *serialise* and later hand back to Ash: an Oban job's args, the cron
  fan-out's args, the scrub's raw `prefix:`, the outgoing tenant tag, and the
  comparison in `AshDispatch.Tenants`.

  `key/1` is not that answer. `Ash.ToTenant`'s own moduledoc teaches

      def to_tenant(%{id: id}, _resource), do: "org_\#{id}"

  so for a struct tenant the two disagree, and a job whose args say `"42"`
  reads a schema that does not exist. (0.9.4-rc.0 used `key/1` here; see the
  CHANGELOG.)

  For a string, atom or integer tenant `Ash.ToTenant` is the identity, so this
  answers exactly what `key/1` does — which is why routing these paths through
  it changes nothing for a host that names its tenants with strings.

  A tenant with no `Ash.ToTenant` implementation falls back to `key/1`: a plain
  map has meant its `:id` since 0.9.0, and Ash would refuse it as a tenant
  anyway. A term that is neither raises
  `AshDispatch.Tenancy.UnsupportedTenantError` rather than letting
  `Protocol.UndefinedError` out of the middle of a dispatch.
  """
  @spec prefix(term(), term()) :: String.t() | nil
  def prefix(resource, tenant)
  def prefix(_resource, nil), do: nil

  def prefix(resource, tenant) do
    case Ash.ToTenant.impl_for(tenant) do
      nil -> Context.tenant_key(tenant)
      _impl -> tenant |> Ash.ToTenant.to_tenant(resource) |> Context.tenant_key()
    end
  end

  @doc """
  `prefix/2` for the configured delivery receipt resource.

  Every value the library serialises is read back against the receipt — the
  send workers read the receipt, the scrub updates its table, the webhook tag
  names the schema its receipt is in — so they all have to agree on one string,
  and this is it.
  """
  @spec receipt_prefix(term()) :: String.t() | nil
  def receipt_prefix(tenant), do: prefix(Config.delivery_receipt_resource(), tenant)

  @doc """
  Remembers the tenant a record was read or written with, on the record.

  A no-op for `nil`, for a pseudo-receipt (a plain map) and for a record of a
  resource without multitenancy — there is nothing to remember and nothing that
  would read it.
  """
  @spec remember(term(), term()) :: term()
  def remember(record, tenant)
  def remember(record, nil), do: record

  def remember(%resource{} = record, tenant) do
    if multitenant?(resource) do
      Ash.Resource.put_metadata(record, @metadata_key, tenant)
    else
      record
    end
  end

  def remember(record, _tenant), do: record

  @doc """
  The tenant a record was read or written with, or `nil`.

  Reads what `remember/2` stored, and falls back to the tenant Ash itself
  records in a struct's metadata — a record the host loaded and handed us
  carries that one, and it is as good an answer.
  """
  @spec of(term()) :: term()
  def of(%{__metadata__: metadata}) when is_map(metadata) do
    Map.get(metadata, @metadata_key) || Map.get(metadata, :tenant)
  end

  def of(_record), do: nil

  @doc """
  Sets the tenant on a changeset, when its resource is multitenant and the
  tenant is not `nil`. Returns the changeset untouched otherwise.
  """
  @spec set(Ash.Changeset.t(), term()) :: Ash.Changeset.t()
  def set(changeset, tenant)
  def set(changeset, nil), do: changeset

  def set(%Ash.Changeset{resource: resource} = changeset, tenant) do
    if multitenant?(resource), do: Ash.Changeset.set_tenant(changeset, tenant), else: changeset
  end

  @doc """
  Sets the tenant on a query, when its resource is multitenant and the tenant
  is not `nil`. Returns the query untouched otherwise.
  """
  @spec set_query(Ash.Query.t(), term()) :: Ash.Query.t()
  def set_query(query, tenant)
  def set_query(query, nil), do: query

  def set_query(%Ash.Query{resource: resource} = query, tenant) do
    if multitenant?(resource), do: Ash.Query.set_tenant(query, tenant), else: query
  end

  @doc """
  The changeset for an update of `record`, in the tenant the record was read
  with. The seam every status transition goes through.
  """
  @spec changeset_for_update(term(), atom(), map()) :: Ash.Changeset.t()
  def changeset_for_update(record, action, attrs \\ %{}) do
    record
    |> Ash.Changeset.for_update(action, attrs)
    |> set(of(record))
  end

  @doc """
  The tenant to work in, given a receipt and the context around it: the one the
  receipt was read with, else the dispatch's.

  The receipt's comes first because it is the schema the row is actually in. On
  a synchronous transport the two are the same; in a worker there is no context
  at all.
  """
  @spec tenant_for(term(), term()) :: term()
  def tenant_for(receipt, context) do
    of(receipt) || context_tenant(context)
  end

  defp context_tenant(%{tenant: tenant}), do: tenant
  defp context_tenant(_context), do: nil

  @doc """
  The tenant an Oban job says to work in — the one place a tenant reaches the
  library from storage rather than from a running dispatch.

  - `{:ok, nil}` — the job carries none. Every job enqueued before 0.9.4
    carries none, which is exactly today's behaviour, and that is what makes
    this safe to deploy while jobs are in flight.
  - `{:ok, tenant}` — the host recognises it, or has not said what its tenants
    are (see below).
  - `{:error, reason}` — the host does not recognise it. The caller cancels:
    a tenant is a Postgres schema name, and an args row that someone has
    edited must not be able to choose which schema is read.

  When `:tenants` is not configured the tenant is allowed through, with a
  warning. The difference from a webhook tag is where the value came from: this
  one the library wrote itself when it enqueued the job, and refusing every
  delivery because a host has not implemented a callback yet would be a worse
  failure than the one it prevents. A webhook tag comes from outside and is
  refused outright (`AshDispatch.WebhookHandlers.Resend`).
  """
  @spec from_job_args(map()) :: {:ok, term()} | {:error, String.t()}
  def from_job_args(args) when is_map(args) do
    case args["tenant"] || args[:tenant] do
      nil ->
        {:ok, nil}

      tenant ->
        case AshDispatch.Tenants.check(tenant) do
          :ok ->
            {:ok, tenant}

          {:error, :not_configured} ->
            AshDispatch.Tenants.warn_if_missing("A send job carries a tenant")
            {:ok, tenant}

          {:error, :unknown_tenant} ->
            {:error, "the job's tenant #{inspect(tenant)} is not one this host recognises"}
        end
    end
  end

  def from_job_args(_args), do: {:ok, nil}

  @doc """
  Whether an error is Postgres saying there is nothing there to read — a tenant
  that was named but whose schema or tables were never created.

  Worth telling apart: it will not fix itself, so the job is cancelled rather
  than retried five times against a schema that is still not there.

  Two forms, because a missing schema is reported as a missing *relation* when
  the name is qualified (`42P01`, not `3F000`), and because Ash sometimes
  carries the Postgrex error as a struct and sometimes as the text of one.
  """
  @spec missing_schema?(term()) :: boolean()
  def missing_schema?(error) do
    error |> flatten() |> Enum.any?(&schema_error?/1)
  end

  @missing_codes [:invalid_schema_name, :undefined_table]
  @missing_text ["invalid_schema_name", "undefined_table", "3F000", "42P01"]

  defp schema_error?(%{postgres: %{code: code}}), do: code in @missing_codes

  defp schema_error?(%{error: text}) when is_binary(text),
    do: Enum.any?(@missing_text, &String.contains?(text, &1))

  defp schema_error?(text) when is_binary(text),
    do: Enum.any?(@missing_text, &String.contains?(text, &1))

  defp schema_error?(_error), do: false

  defp flatten(%{errors: errors}) when is_list(errors),
    do: Enum.flat_map(errors, &flatten/1)

  defp flatten(%{error: error} = outer) when is_map(error), do: [outer | flatten(error)]
  defp flatten(error), do: [error]
end
