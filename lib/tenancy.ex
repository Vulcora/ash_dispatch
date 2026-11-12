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
  The tenant as the library stores and compares it — `AshDispatch.Context.tenant_key/1`.
  """
  @spec key(term()) :: String.t() | nil
  def key(tenant), do: Context.tenant_key(tenant)

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
  The changeset for an update of `record`, in the tenant the record was read
  with. The seam every status transition goes through.
  """
  @spec changeset_for_update(term(), atom(), map()) :: Ash.Changeset.t()
  def changeset_for_update(record, action, attrs \\ %{}) do
    record
    |> Ash.Changeset.for_update(action, attrs)
    |> set(of(record))
  end
end
