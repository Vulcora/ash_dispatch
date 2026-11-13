defmodule AshDispatch.Tenancy.OddTenantsTest do
  @moduledoc """
  A tenant is a Postgres schema name, so the properties that matter about an
  odd one: it cannot become SQL, and it cannot reach the database unless the
  host listed it.

  Kept from the independent review of 0.9.4-rc.0, which found this half sound.
  It is cheaper to keep the checks than to have the next reader redo them.
  """
  use AshDispatch.Test.PerTenantCase, async: false

  alias AshDispatch.Tenancy.Cron
  alias AshDispatch.Tenants
  alias AshDispatch.Workers.ScrubSensitiveContent

  @moduletag :postgres
  @moduletag :capture_log

  describe "a tenant name that tries to be SQL" do
    @evil ~s(tenant_a"; drop schema "tenant_b"; --)

    test "is quoted as an identifier on the Ash path" do
      assert {:error, error} = Ash.read(PerTenant.Receipt, authorize?: false, tenant: @evil)
      refute inspect(error) =~ "DROP"

      assert PerTenant.Repo.query!(~s(select 1 from "tenant_b"."pt_receipts" limit 1))
    end

    test "and on the scrub's raw prefix" do
      Application.put_env(:ash_dispatch, :scrub_after_hours, 0)
      on_exit(fn -> Application.delete_env(:ash_dispatch, :scrub_after_hours) end)

      receipt =
        "tenant_b"
        |> receipt!(%{event_id: "pt_meeting.cancelled", body_text: "the code is 123456"})
        |> AshDispatch.ReceiptStatus.mark_sent(%{})

      try do
        ScrubSensitiveContent.perform(%Oban.Job{args: %{"tenant" => ~s(tenant_a" , "x)}})
      rescue
        # Either Ecto refuses the name or Postgres cannot find it. Both are
        # fine; that tenant_b's body survives is the property.
        _ -> :ok
      end

      assert Ash.get!(PerTenant.Receipt, receipt.id, authorize?: false, tenant: "tenant_b").body_text ==
               "the code is 123456"

      assert PerTenant.Repo.query!(~s(select 1 from "tenant_a"."pt_receipts" limit 1))
    end
  end

  describe "an odd name the host did not list" do
    test "is refused by check/1" do
      for odd <- [
            "public",
            "pg_catalog",
            "information_schema",
            "",
            "TENANT_A",
            String.duplicate("a", 300),
            "tenant_a ",
            " tenant_a"
          ] do
        assert Tenants.check(odd) == {:error, :unknown_tenant},
               "#{inspect(odd)} was accepted as a tenant"
      end

      assert Tenants.check("tenant_a") == :ok
    end

    test "and a cron pass for it does nothing" do
      assert Cron.plan(%{"tenant" => "public"}) == :no_tenants
      assert Cron.plan(%{"tenant" => "pg_catalog"}) == :no_tenants
    end
  end
end
