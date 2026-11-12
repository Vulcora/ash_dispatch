defmodule AshDispatch.Tenancy.Base do
  @moduledoc """
  The `multitenancy:` and `tenant_column:` options of the `Base` macros, in one
  place.

  Three resources take them (`AshDispatch.Resources.DeliveryReceipt.Base`,
  `Notification.Base`, `Preference.Base`) and all three must read them the same
  way, including the part that matters most: **absent, they emit nothing.** A
  resource built without them declares no multitenancy and has no new column,
  so its DSL is what 0.9.3 generated and `AshDispatch.Tenancy.opts/2` never
  hands it a tenant.

  Not for a host to call.
  """

  @doc """
  The `multitenancy` block for the option, or `nil` for none.

  - `nil` or `false` — nothing. A resource with no multitenancy.
  - `:context` — `strategy :context`, `global? false`. One schema per tenant,
    and a read or write without a tenant fails rather than falling through to
    the public schema.
  - `{:context, global?: true}` — the same, but a read without a tenant is
    allowed. For a host with both tenant-scoped and system-wide events; it has
    to know, at every call site of its own, which schema it means.
  """
  @spec block(term()) :: Macro.t() | nil
  def block(option)
  def block(nil), do: nil
  def block(false), do: nil

  def block(:context), do: block({:context, global?: false})

  def block({:context, opts}) when is_list(opts) do
    global? = Keyword.get(opts, :global?, false) == true

    quote do
      multitenancy do
        strategy :context
        global?(unquote(global?))
      end
    end
  end

  def block(other) do
    raise ArgumentError, """
    AshDispatch: `multitenancy: #{inspect(other)}` is not a value this base understands.

    Expected `:context` or `{:context, global?: true}`. Leave the option out for
    a resource whose rows live in one schema for every tenant, which is the
    default and what every release before 0.9.4 did.
    """
  end

  @doc """
  The `tenant` attribute for `tenant_column: true`, or `nil`.

  A plain nullable string, filled from `AshDispatch.Context.tenant_key/1` when
  a receipt is created — the same column `Notification.Base` has had since
  0.9.0. Nullable, so existing rows need no backfill.
  """
  @spec attribute(term()) :: Macro.t() | nil
  def attribute(option)
  def attribute(true), do: quote(do: attribute(:tenant, :string, allow_nil?: true, public?: true))
  def attribute(_option), do: nil
end
