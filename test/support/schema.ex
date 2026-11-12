defmodule AshDispatch.Test.Schema do
  @moduledoc """
  Creates a real Postgres schema and the tables of an AshPostgres resource in
  it, from the resource's own attributes and identities.

  The per-tenant tests need real schemas — `strategy :context` *is* a schema
  prefix, and a temporary table lives in `pg_temp`, which cannot be addressed
  as `tenant_a`. Writing the DDL out by hand would be twenty-five columns per
  resource that drift the first time a column is added to a base; generating it
  from `Ash.Resource.Info` keeps the fixture honest instead, and a column the
  base gains tomorrow appears here without anyone remembering.

  Only the types the library's own resources use are mapped. A resource that
  reaches the catch-all raises rather than guessing.
  """

  @doc """
  Creates `prefix` (dropping it first) and one table per resource in it.

  `prefix: nil` creates the tables in the repo's default schema, for a resource
  that is not per tenant.
  """
  @spec create!(module(), [module()], String.t() | nil) :: :ok
  def create!(repo, resources, prefix) do
    if prefix do
      repo.query!(~s(drop schema if exists "#{prefix}" cascade))
      repo.query!(~s(create schema "#{prefix}"))
    end

    Enum.each(resources, &create_table!(repo, &1, prefix))
  end

  @doc "Drops the schema and everything in it."
  @spec drop!(module(), String.t()) :: :ok
  def drop!(repo, prefix) do
    repo.query!(~s(drop schema if exists "#{prefix}" cascade))
    :ok
  end

  @doc "Drops one resource's table from the repo's default schema."
  @spec drop_table!(module(), module()) :: :ok
  def drop_table!(repo, resource) do
    repo.query!(~s(drop table if exists "#{table(resource)}" cascade))
    :ok
  end

  defp create_table!(repo, resource, prefix) do
    columns =
      resource
      |> Ash.Resource.Info.attributes()
      |> Enum.map_join(",\n  ", &column/1)

    repo.query!("create table #{qualified(resource, prefix)} (\n  #{columns}\n)")

    Enum.each(Ash.Resource.Info.identities(resource), &index!(repo, resource, prefix, &1))
  end

  defp column(attribute) do
    type = pg_type(Ash.Type.storage_type(attribute.type, attribute.constraints))

    [
      ~s("#{attribute.name}"),
      type,
      if(attribute.primary_key?, do: "primary key"),
      if(not attribute.allow_nil? and not attribute.primary_key?, do: "not null")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp index!(repo, resource, prefix, identity) do
    where = wheres(resource)[identity.name]

    # An identity whose `where` has no SQL spelled out (`identity_wheres_to_sql`
    # in the postgres block) cannot be rendered here. Skipping it would make the
    # fixture quietly weaker than the real table, so say so.
    if identity.where && is_nil(where) do
      raise """
      #{inspect(resource)}'s identity #{inspect(identity.name)} has a `where` that this
      fixture cannot render. Add `identity_wheres_to_sql(#{identity.name}: "...")` to the
      resource's postgres block, as the library's own bases do.
      """
    end

    keys = Enum.map_join(identity.keys, ", ", &~s("#{&1}"))

    repo.query!(
      "create unique index #{identity.name}_#{suffix(prefix)} " <>
        "on #{qualified(resource, prefix)} (#{keys})" <>
        if(identity.nils_distinct? == false, do: " nulls not distinct", else: "") <>
        if(where, do: " where (#{where})", else: "")
    )
  end

  defp wheres(resource) do
    AshPostgres.DataLayer.Info.identity_wheres_to_sql(resource) || []
  rescue
    _ -> []
  end

  defp suffix(nil), do: "public_idx"
  defp suffix(prefix), do: "#{prefix}_idx"

  defp table(resource), do: AshPostgres.DataLayer.Info.table(resource)

  defp qualified(resource, nil), do: ~s("#{table(resource)}")
  defp qualified(resource, prefix), do: ~s("#{prefix}"."#{table(resource)}")

  defp pg_type(:uuid), do: "uuid"
  defp pg_type(:string), do: "text"
  defp pg_type(:text), do: "text"
  defp pg_type(:map), do: "jsonb"
  defp pg_type(:boolean), do: "boolean"
  defp pg_type(:integer), do: "bigint"
  defp pg_type(:bigint), do: "bigint"
  defp pg_type(:utc_datetime_usec), do: "timestamp(6)"
  defp pg_type(:utc_datetime), do: "timestamp(0)"
  defp pg_type(:naive_datetime), do: "timestamp(0)"
  defp pg_type(:date), do: "date"

  defp pg_type(other) do
    raise ArgumentError,
          "AshDispatch.Test.Schema does not know the Postgres type for #{inspect(other)}. " <>
            "Add it — guessing would make the fixture lie about the real table."
  end
end
