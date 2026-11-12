defmodule AshDispatch.TenancyTest do
  @moduledoc """
  `AshDispatch.Tenancy` carries the whole compatibility story of 0.9.4: it is
  the one place that decides whether a tenant is mentioned to Ash at all, and
  it answers "no" for every resource that declares no multitenancy — which is
  every resource every host had before this release.
  """
  use ExUnit.Case, async: false

  alias AshDispatch.Tenancy
  alias AshDispatch.Test.TransportReceipt

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshDispatch.TenancyTest.Public
      resource AshDispatch.TenancyTest.PerTenant
    end
  end

  defmodule Public do
    @moduledoc false
    use Ash.Resource, domain: AshDispatch.TenancyTest.Domain, data_layer: Ash.DataLayer.Ets

    ets do
      private? true
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
    end

    actions do
      defaults [:read, :destroy, create: [:name], update: [:name]]
    end
  end

  defmodule PerTenant do
    @moduledoc false
    use Ash.Resource, domain: AshDispatch.TenancyTest.Domain, data_layer: Ash.DataLayer.Ets

    ets do
      private? true
    end

    multitenancy do
      strategy :context
      global? false
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
    end

    actions do
      defaults [:read, :destroy, create: [:name], update: [:name]]
    end
  end

  describe "multitenant?/1" do
    test "a resource without a multitenancy block is not" do
      refute Tenancy.multitenant?(Public)
      refute Tenancy.multitenant?(TransportReceipt)
    end

    test "a resource with strategy :context is" do
      assert Tenancy.multitenant?(PerTenant)
    end

    test "anything that is not a resource is not — a pseudo-receipt is a map" do
      refute Tenancy.multitenant?(nil)
      refute Tenancy.multitenant?(%{id: nil})
      refute Tenancy.multitenant?(:not_a_module)
      refute Tenancy.multitenant?(Enum)
    end
  end

  describe "opts/2 — the compatibility seam" do
    test "nothing for a resource that declares no multitenancy, tenant or not" do
      assert Tenancy.opts(Public, "org_1") == []
      assert Tenancy.opts(Public, nil) == []
      assert Tenancy.opts(TransportReceipt, "org_1") == []
    end

    test "nothing when there is no tenant, multitenant or not" do
      assert Tenancy.opts(PerTenant, nil) == []
    end

    test "the tenant when both are true" do
      assert Tenancy.opts(PerTenant, "org_1") == [tenant: "org_1"]
    end
  end

  describe "remember/2 and of/1" do
    test "a tenant travels on the record it was read with" do
      record = %PerTenant{id: Ash.UUID.generate()}

      assert Tenancy.of(record) == nil
      assert Tenancy.of(Tenancy.remember(record, "org_1")) == "org_1"
    end

    test "nothing is remembered on a resource without multitenancy" do
      record = %Public{id: Ash.UUID.generate()}
      assert Tenancy.of(Tenancy.remember(record, "org_1")) == nil
    end

    test "nothing is remembered for a nil tenant, or on a plain map" do
      record = %PerTenant{id: Ash.UUID.generate()}
      assert Tenancy.of(Tenancy.remember(record, nil)) == nil
      assert Tenancy.remember(%{id: nil}, "org_1") == %{id: nil}
      assert Tenancy.of(%{id: nil}) == nil
    end

    test "the tenant Ash itself records on a struct is read as well" do
      record =
        %PerTenant{id: Ash.UUID.generate()}
        |> Ash.Resource.put_metadata(:tenant, "org_2")

      assert Tenancy.of(record) == "org_2"
    end
  end

  describe "set/2 and changeset_for_update/3" do
    test "the tenant reaches a changeset of a multitenant resource" do
      changeset =
        PerTenant
        |> Ash.Changeset.for_create(:create, %{name: "a"})
        |> Tenancy.set("org_1")

      assert changeset.tenant == "org_1"
    end

    test "and never one of a resource without multitenancy" do
      changeset =
        Public
        |> Ash.Changeset.for_create(:create, %{name: "a"})
        |> Tenancy.set("org_1")

      assert changeset.tenant == nil
    end

    test "an update takes the tenant from the record it updates" do
      record =
        %PerTenant{id: Ash.UUID.generate(), name: "a"}
        |> Ash.Resource.put_metadata(:ash_dispatch_tenant, "org_1")

      assert Tenancy.changeset_for_update(record, :update, %{name: "b"}).tenant == "org_1"
    end

    test "and none when the record carries none" do
      record = %PerTenant{id: Ash.UUID.generate(), name: "a"}
      assert Tenancy.changeset_for_update(record, :update, %{name: "b"}).tenant == nil
    end
  end

  describe "the per-resource questions" do
    setup do
      saved =
        for key <- [:delivery_receipt_resource, :notification_resource, :preference_resource] do
          {key, Application.get_env(:ash_dispatch, key)}
        end

      on_exit(fn ->
        for {key, value} <- saved do
          if is_nil(value),
            do: Application.delete_env(:ash_dispatch, key),
            else: Application.put_env(:ash_dispatch, key, value)
        end
      end)

      :ok
    end

    test "answer for the configured resources, and are false when unconfigured" do
      for key <- [:delivery_receipt_resource, :notification_resource, :preference_resource] do
        Application.delete_env(:ash_dispatch, key)
      end

      refute Tenancy.receipts_per_tenant?()
      refute Tenancy.notifications_per_tenant?()
      refute Tenancy.preferences_per_tenant?()

      Application.put_env(:ash_dispatch, :delivery_receipt_resource, PerTenant)
      Application.put_env(:ash_dispatch, :notification_resource, Public)

      assert Tenancy.receipts_per_tenant?()
      refute Tenancy.notifications_per_tenant?()
    end
  end
end
