defmodule AshDispatch.Tenancy.UnsupportedTenantError do
  @moduledoc """
  A tenant the library cannot reduce to a string.

  `AshDispatch.Context.tenant_key/1` stores a tenant in the `tenant` column as
  a string: a binary as it is, a record by its `:id`, anything else through
  `to_string/1`. A struct with neither an `:id` nor a `String.Chars`
  implementation has no answer, and before 0.9.4-rc.1 it left a bare
  `Protocol.UndefinedError` out of wherever the library happened to be — the
  middle of a dispatch, building an Oban job's args.

  Such a tenant is still perfectly usable for the *schema*: implement
  `Ash.ToTenant` for it and `AshDispatch.Tenancy.prefix/2` will ask that.
  This error is only about the column.
  """

  defexception [:tenant]

  @impl true
  def message(%{tenant: tenant}) do
    """
    ash_dispatch cannot reduce #{inspect(tenant)} to a tenant key.

    The `tenant` column stores a string, and this term is neither a string, a
    number, an atom, nor a record with an `:id`. Either:

      * give it an `:id`, or a `String.Chars` implementation, so
        `AshDispatch.Context.tenant_key/1` has an answer; or
      * pass the tenant in a shape the column can hold (its id, its schema
        name) and keep the struct for Ash, which asks `Ash.ToTenant`.

    `Ash.ToTenant` decides which SCHEMA the tenant's rows live in and is asked
    separately (`AshDispatch.Tenancy.prefix/2`), so implementing it does not
    answer this.
    """
  end
end
