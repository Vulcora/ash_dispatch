defmodule AshDispatch.Tenancy.SchemaFixtureTest do
  @moduledoc """
  The fixture itself: two real Postgres schemas, each with the library's own
  tables in it, generated from the resources' attributes and identities.

  Every per-tenant test below rests on this, so it is checked directly — a
  fixture that silently creates one schema, or a table missing the column the
  test is about, would turn every assertion that follows into a test of
  nothing.
  """
  use AshDispatch.Test.PerTenantCase, async: false

  @moduletag :postgres

  test "both tenants have the three tables, and they are separate" do
    for tenant <- tenants() do
      assert receipts(tenant) == []
      assert notifications(tenant) == []
      assert preferences(tenant) == []
    end

    a = receipt!("tenant_a", %{recipient: "a@example.com"})

    assert Enum.map(receipts("tenant_a"), & &1.id) == [a.id]
    assert receipts("tenant_b") == []

    # And it really is a schema, not a column with a filter on it.
    assert a.__meta__.prefix == "tenant_a"
  end

  test "the generated table has every column the base declares" do
    columns =
      PerTenant.Repo.query!("""
      select column_name from information_schema.columns
      where table_schema = 'tenant_a' and table_name = 'pt_receipts'
      """)
      |> Map.fetch!(:rows)
      |> List.flatten()
      |> MapSet.new()

    declared =
      PerTenant.Receipt
      |> Ash.Resource.Info.attributes()
      |> MapSet.new(&to_string(&1.name))

    assert MapSet.subset?(declared, columns),
           "missing: #{inspect(MapSet.difference(declared, columns))}"
  end

  test "the identities are indexes, with the base's nulls-not-distinct where it asks" do
    rows =
      PerTenant.Repo.query!("""
      select indexdef from pg_indexes
      where schemaname = 'tenant_a' and tablename = 'pt_preferences'
      """)
      |> Map.fetch!(:rows)
      |> List.flatten()

    assert Enum.any?(rows, &(&1 =~ "NULLS NOT DISTINCT")),
           "the scope identity's NULLS NOT DISTINCT is missing: #{inspect(rows)}"
  end

  test "a read without a tenant is refused, not answered from the public schema" do
    receipt!("tenant_a", %{})

    assert_raise Ash.Error.Invalid, fn ->
      Ash.read!(PerTenant.Receipt, authorize?: false)
    end
  end

  test "the public receipt resource lives in one schema and takes a tenant column" do
    {:ok, receipt} =
      PerTenant.PublicReceipt
      |> Ash.Changeset.for_create(:create, %{
        event_id: "pt_meeting.updated",
        transport: :email,
        audience: :user,
        recipient: "x@example.com",
        tenant: "tenant_a"
      })
      |> Ash.create(authorize?: false)

    assert receipt.tenant == "tenant_a"
    assert [%{tenant: "tenant_a"}] = Ash.read!(PerTenant.PublicReceipt, authorize?: false)
  end
end
