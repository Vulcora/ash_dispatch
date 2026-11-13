defmodule AshDispatch.Resources.PrimaryKey do
  @moduledoc """
  The `primary_key:` option of the `Base` macros, in one place.

  Three resources take it (`AshDispatch.Resources.DeliveryReceipt.Base`,
  `Notification.Base`, `Preference.Base`) and all three must read it the same
  way, including the part that matters most: **absent, each base keeps the key
  it has always had.** `Notification.Base` and `Preference.Base` default to
  `:uuid_v7`, `DeliveryReceipt.Base` to `:uuid`, and nothing about a host that
  does not pass the option changes.

  ## Why it exists

  `uuid_v7_primary_key` makes `mix ash.codegen` write
  `default: fragment("uuid_generate_v7()")` into the migration. That function
  is not built into Postgres before 18: ash_postgres creates it, in the
  `ash-functions` migration, and only for a repo whose `installed_extensions/0`
  lists `"ash-functions"`. Where it is missing, `CREATE TABLE` fails — and for
  a host that creates a tenant's tables when the tenant is created, that means
  no tenant can be created at all (#50).

  Installing the function is the better answer and the guides say how. This
  option is for a host that cannot: a managed database that will not define
  functions, or a schema owned by someone else.

  Both kinds store the same column — `:uuid_v7`'s storage type is `uuid` —
  so the choice changes the column's DEFAULT and nothing else. Make it before
  the first migration; changing it afterwards is an `ALTER COLUMN … SET
  DEFAULT` that `mix ash.codegen` will generate for you, and ids already
  written keep working either way.

  Not for a host to call.
  """

  @kinds [:uuid_v7, :uuid]

  @doc """
  The primary-key attribute for `option`, or for `default` when it is absent.

  - `nil` — `default`, which is the base's own and unchanged
  - `:uuid_v7` — `uuid_v7_primary_key :id`, whose migration default is
    `uuid_generate_v7()`
  - `:uuid` — `uuid_primary_key :id`, whose migration default is
    `gen_random_uuid()`, built into Postgres 13 and later
  """
  @spec attribute(:uuid_v7 | :uuid, term()) :: Macro.t()
  def attribute(default, option)

  def attribute(default, nil) when default in @kinds, do: attribute(default, default)
  def attribute(_default, :uuid_v7), do: quote(do: uuid_v7_primary_key(:id))
  def attribute(_default, :uuid), do: quote(do: uuid_primary_key(:id))

  def attribute(_default, other) do
    raise ArgumentError, """
    AshDispatch: `primary_key: #{inspect(other)}` is not a value this base understands.

    Expected `:uuid_v7` or `:uuid`. Leave the option out to keep the key this
    resource has always had, which is what every release before 0.9.4-rc.2 did
    and what every host that does not set it still gets.
    """
  end
end
