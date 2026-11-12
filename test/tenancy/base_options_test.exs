defmodule AshDispatch.Tenancy.BaseOptionsTest do
  @moduledoc """
  What `multitenancy:` and `tenant_column:` do to a resource — and, more
  importantly, what their absence does: nothing at all.
  """
  use ExUnit.Case, async: true

  alias AshDispatch.Tenancy
  alias AshDispatch.Test.PerTenant

  describe "without the options" do
    # The 0.9.3 fixtures, compiled from the same bases without the new options.
    test "a receipt resource declares no multitenancy and has no tenant column" do
      receipt = AshDispatch.Test.Setup.Deliveries.DeliveryReceipt

      assert Ash.Resource.Info.multitenancy_strategy(receipt) == nil
      refute Tenancy.multitenant?(receipt)
      assert Ash.Resource.Info.attribute(receipt, :tenant) == nil
    end

    test "a notification resource declares no multitenancy — but keeps its tenant column" do
      notification = AshDispatch.Test.Setup.Notification

      assert Ash.Resource.Info.multitenancy_strategy(notification) == nil
      # The column has been there since 0.9.0 and is a different thing from the
      # schema: it says which tenant a notification belongs to, in one table.
      assert %{name: :tenant} = Ash.Resource.Info.attribute(notification, :tenant)
    end
  end

  describe "multitenancy: :context" do
    test "declares strategy :context, and refuses a read without a tenant" do
      for resource <- [PerTenant.Receipt, PerTenant.Notification, PerTenant.Preference] do
        assert Ash.Resource.Info.multitenancy_strategy(resource) == :context, inspect(resource)
        refute Ash.Resource.Info.multitenancy_global?(resource), inspect(resource)
        assert Tenancy.multitenant?(resource), inspect(resource)
      end
    end

    test "a tenant then reaches Tenancy.opts/2" do
      assert Tenancy.opts(PerTenant.Receipt, "tenant_a") == [tenant: "tenant_a"]
    end
  end

  describe "tenant_column: true" do
    test "adds a nullable tenant column and accepts it on create" do
      assert %{name: :tenant, allow_nil?: true} =
               Ash.Resource.Info.attribute(PerTenant.PublicReceipt, :tenant)

      accepted = Ash.Resource.Info.action(PerTenant.PublicReceipt, :create).accept
      assert :tenant in accepted
    end

    test "and leaves the resource in one schema for every tenant" do
      refute Tenancy.multitenant?(PerTenant.PublicReceipt)
      assert Tenancy.opts(PerTenant.PublicReceipt, "tenant_a") == []
    end
  end

  describe "a value the base does not understand" do
    test "is refused at compile time, with what it expected" do
      assert_raise ArgumentError, ~r/not a value this base understands/, fn ->
        AshDispatch.Tenancy.Base.block(:per_schema)
      end
    end

    test "global? true is the escape hatch, and says so in the DSL" do
      assert {_, _, _} = AshDispatch.Tenancy.Base.block({:context, global?: true})
      assert AshDispatch.Tenancy.Base.block(nil) == nil
      assert AshDispatch.Tenancy.Base.block(false) == nil
    end
  end
end
