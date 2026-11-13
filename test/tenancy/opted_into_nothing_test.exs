defmodule AshDispatch.Tenancy.OptedIntoNothingTest do
  @moduledoc """
  Two ways 0.9.4-rc.0 reached a host that opted into nothing — no
  `multitenancy:`, no `tenant_column:`, and no reason to read the Tenancy
  guide, which tells it the page does not apply ("a host that does nothing
  sees nothing of this page").
  """
  use ExUnit.Case, async: true

  alias AshDispatch.Tenancy

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshDispatch.Tenancy.OptedIntoNothingTest.HandRolledReceipt
    end
  end

  defmodule HandRolledReceipt do
    @moduledoc """
    A receipt resource of the host's own that already has a `tenant` attribute
    with a default, and accepts it on `:create`. Hand-rolled receipts are
    explicitly supported and are the reason `skip_unknown_inputs` is in the
    dispatcher at all.
    """
    use Ash.Resource, domain: Domain, data_layer: Ash.DataLayer.Ets

    ets do
      private? true
    end

    attributes do
      uuid_primary_key :id
      attribute :event_id, :string, public?: true
      attribute :tenant, :string, default: "legacy", public?: true
    end

    actions do
      defaults [:read]

      create :create do
        accept [:event_id, :tenant]
      end
    end
  end

  # Exactly what `AshDispatch.Dispatcher` passes.
  @skip_unknown_inputs [:notification_id, :actor_id, :tenant]

  describe "a tenant key in the receipt's create attrs" do
    # `skip_unknown_inputs` drops an input the action does not accept. It does
    # not drop one it does — and Ash applies an attribute's default only when
    # the input is ABSENT, so rc.0's unconditional `tenant: nil` wrote nil over
    # the host's own default on every dispatch without a tenant.
    test "an absent key leaves the host's default alone" do
      assert create(%{event_id: "e"}).tenant == "legacy"
    end

    test "an explicit nil would not, which is why the dispatcher omits it" do
      assert create(%{event_id: "e", tenant: nil}).tenant == nil
    end

    test "and the dispatcher's attrs for a dispatch with no tenant carry no :tenant key" do
      # `:unreachable` because this case configures no `recipient_fields`; the
      # attrs are built either way, which is what is under test.
      {_status, attrs} =
        AshDispatch.Dispatcher.build_receipt(
          %AshDispatch.Context{event_id: "e", data: %{}, tenant: nil},
          %AshDispatch.Channel{transport: :email, audience: :user},
          %{},
          %{id: Ash.UUID.generate(), email: "someone@example.com"}
        )

      refute Map.has_key?(attrs, :tenant)
    end

    test "while a dispatch that has one still records it" do
      # `:unreachable` because this case configures no `recipient_fields`; the
      # attrs are built either way, which is what is under test.
      {_status, attrs} =
        AshDispatch.Dispatcher.build_receipt(
          %AshDispatch.Context{event_id: "e", data: %{}, tenant: "org_1"},
          %AshDispatch.Channel{transport: :email, audience: :user},
          %{},
          %{id: Ash.UUID.generate(), email: "someone@example.com"}
        )

      assert attrs.tenant == "org_1"
    end
  end

  describe "the tenant Ash records in a record's metadata" do
    setup do
      previous = Application.fetch_env(:ash_dispatch, :delivery_receipt_resource)
      previous_tenants = Application.fetch_env(:ash_dispatch, :tenants)

      Application.put_env(
        :ash_dispatch,
        :delivery_receipt_resource,
        AshDispatch.Test.TransportReceipt
      )

      on_exit(fn ->
        restore(:delivery_receipt_resource, previous)
        restore(:tenants, previous_tenants)
      end)

      :ok
    end

    defp restore(key, {:ok, value}), do: Application.put_env(:ash_dispatch, key, value)
    defp restore(key, :error), do: Application.delete_env(:ash_dispatch, key)

    # The host's own app passes its tenant to every Ash call. The receipt
    # resource declares no multitenancy, so Ash ignores it — and records it.
    defp host_receipt do
      AshDispatch.Test.TransportReceipt
      |> Ash.Changeset.for_create(:create, %{
        event_id: "meeting.updated",
        audience: :user,
        transport: :email,
        recipient: "someone@example.com",
        subject: "Meeting",
        body_text: "moved"
      })
      |> Ash.create!(authorize?: false, tenant: "org_1")
    end

    test "is not read back for a resource that declares no multitenancy" do
      receipt = host_receipt()

      refute Tenancy.multitenant?(AshDispatch.Test.TransportReceipt)
      assert Map.get(receipt.__metadata__, :tenant) == "org_1"
      assert Tenancy.of(receipt) == nil
    end

    test "so the send job it builds carries no tenant" do
      args = Tenancy.Job.put_tenant(%{"receipt_id" => host_receipt().id}, host_receipt())

      refute Map.has_key?(args, "tenant")
    end

    test "and the job is not cancelled by a tenant the library invented" do
      # The host configured :tenants for some other reason — its notification
      # resource is per tenant, say — and the tenant Ash recorded is not on
      # that list.
      Application.put_env(:ash_dispatch, :tenants, fn -> ["org_2"] end)

      receipt = host_receipt()
      args = Tenancy.Job.put_tenant(%{"receipt_id" => receipt.id}, receipt)

      assert {:ok, _receipt} = Tenancy.Job.receipt(args)
    end

    test "while what remember/2 stored is still read back" do
      # The gate is on Ash's key only. `remember/2` writes its own, and only
      # for a multitenant resource, so it needs none.
      receipt = Tenancy.remember(host_receipt(), "org_1")

      assert Tenancy.of(receipt) == nil

      assert Tenancy.of(%{__metadata__: %{ash_dispatch_tenant: "org_1"}}) == "org_1"
    end
  end

  defp create(attrs) do
    HandRolledReceipt
    |> Ash.Changeset.for_create(:create, attrs, skip_unknown_inputs: @skip_unknown_inputs)
    |> Ash.create!(authorize?: false)
  end
end
