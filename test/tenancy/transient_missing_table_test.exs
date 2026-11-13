defmodule AshDispatch.Tenancy.TransientMissingTableTest do
  @moduledoc """
  A tenant mid-migration is retried, not cancelled.

  `42P01` (`undefined_table`) is what Postgres says for a schema that exists
  but whose tables are not there *yet* — a tenant between `create schema` and
  `mix ash.migrate`, and every tenant during a deploy that adds a table.
  0.9.4-rc.0's `missing_schema?/1` matched it and `Tenancy.Job` cancelled, so
  every send enqueued in that window was destroyed: a cancelled Oban job never
  runs again and the receipt was left `:scheduled`.

  It also searched the error's free TEXT for `"42P01"`, so a nested message
  about any other relation cancelled the send too.
  """
  use AshDispatch.Test.PerTenantCase, async: false

  alias AshDispatch.Tenancy
  alias AshDispatch.Workers.SendEmail

  @moduletag :postgres
  @moduletag :capture_log

  test "a tenant whose table is being migrated is retried" do
    receipt = receipt!("tenant_a", %{status: :scheduled})
    args = %{"receipt_id" => receipt.id, "tenant" => "tenant_a"}

    # The deploy is between `create schema` and `ash.migrate`: the schema is
    # there, the table is not (yet). `AshDispatch.Test.Schema.create!/3` drops
    # and rebuilds the schema in every setup, so nothing has to put it back.
    PerTenant.Repo.query!(~s(alter table "tenant_a"."pt_receipts" rename to pt_receipts_wip))

    assert {:error, _reason} = SendEmail.perform(%Oban.Job{args: args, attempt: 1})
  end

  test "an undefined_table is not read as a refused schema name" do
    assert_raise Postgrex.Error, fn ->
      PerTenant.Repo.query!(~s(select * from "tenant_a"."no_such_table"))
    end

    error =
      try do
        PerTenant.Repo.query!(~s(select * from "tenant_a"."no_such_table"))
      rescue
        e -> e
      end

    assert error.postgres.code == :undefined_table
    refute Tenancy.missing_schema?(error)
  end

  test "a schema name Postgres refuses is still a reason to cancel" do
    error =
      try do
        PerTenant.Repo.query!(~s|create table "no_such_schema"."t" (id int)|)
      rescue
        e -> e
      end

    assert error.postgres.code == :invalid_schema_name
    assert Tenancy.missing_schema?(error)
    assert Tenancy.missing_schema?(%{errors: [%{error: error}]})
  end

  # The free-text arm matched any nested error that mentioned the code,
  # whatever relation it was about.
  test "an error that merely mentions a code in its text is not a missing schema" do
    refute Tenancy.missing_schema?(%{
             errors: [
               %{
                 error:
                   "** (Postgrex.Error) ERROR 42P01 (undefined_table) relation " <>
                     "\"public.oban_jobs\" does not exist"
               }
             ]
           })

    refute Tenancy.missing_schema?(%{
             errors: [
               %{error: "ERROR 3F000 (invalid_schema_name) schema \"other\" does not exist"}
             ]
           })
  end
end
