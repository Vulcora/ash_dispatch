defmodule AshDispatch.Tenancy.MissedReadsTest do
  @moduledoc """
  Three reads of the host's own resources that 0.9.4-rc.0 left untenanted, and
  that all fail **closed** behind a `rescue`: a per-tenant host loses
  deliveries and counters with nothing but a log line.

  - `AshDispatch.Event.Helpers.evaluate_user_filter/2` — the DSL's
    `should_send_filter`. The query raised `TenantRequired`, the rescue
    answered `false`, and the channel was skipped with a `Logger.debug`:
    nothing sent, no receipt written.
  - `AshDispatch.Helpers.CounterLoader`'s audience check — the same read,
    rescued the same way, so every filtered audience's counters vanished even
    though `load_counters_for_user/2` had been given a `:tenant`.
  - `AshDispatch.Notifier.CounterHandler.load_and_traverse_path/3` — it was
    *given* a `tenant` parameter in rc.0 and its only caller still passed two
    arguments, so the tenant there was always `nil`.
  """
  use AshDispatch.Test.PerTenantCase, async: false

  alias AshDispatch.Event.Helpers
  alias AshDispatch.Helpers.CounterLoader
  alias AshDispatch.Notifier.CounterHandler

  @moduletag :postgres
  @moduletag :capture_log

  require Ash.Query

  describe "a should_send_filter on a per-tenant user resource" do
    setup do
      Application.put_env(:ash_dispatch, :user_module, PerTenant.Booking)
      Application.put_env(:ash_dispatch, :user_resource, PerTenant.Booking)
      Application.put_env(:ash_dispatch, :user_domain, PerTenant.Domain)

      on_exit(fn ->
        Application.delete_env(:ash_dispatch, :user_module)
        Application.delete_env(:ash_dispatch, :user_resource)
        Application.delete_env(:ash_dispatch, :user_domain)
      end)

      :ok
    end

    test "matches the record in the tenant it was given" do
      booking = booking!("tenant_a")

      # The record exists, in tenant_a, and matches the filter.
      assert [%{id: found}] =
               PerTenant.Booking
               |> Ash.Query.filter(reference: booking.reference)
               |> Ash.read!(authorize?: false, tenant: "tenant_a")

      assert found == booking.id

      assert Helpers.evaluate_user_filter(booking, [reference: booking.reference], "tenant_a")
    end

    test "and finds nothing in another tenant" do
      booking = booking!("tenant_a")

      refute Helpers.evaluate_user_filter(booking, [reference: booking.reference], "tenant_b")
    end

    test "with no tenant it still fails closed, as it always did" do
      booking = booking!("tenant_a")

      refute Helpers.evaluate_user_filter(booking, reference: booking.reference)
    end

    test "the filter is still evaluated with no tenant for a resource that is not per tenant" do
      # The compatibility half: `Tenancy.opts/2` answers `[]`, so the read is
      # the read 0.9.3 made.
      Application.put_env(:ash_dispatch, :user_module, AshDispatch.Test.TransportReceipt)

      refute AshDispatch.Tenancy.multitenant?(AshDispatch.Test.TransportReceipt)

      assert Helpers.evaluate_user_filter(%{id: Ash.UUID.generate()}, transport: :email) ==
               false
    end
  end

  describe "a counter audience with a filter" do
    setup do
      Application.put_env(:ash_dispatch, :user_module, PerTenant.Booking)
      Application.put_env(:ash_dispatch, :user_resource, PerTenant.Booking)
      Application.put_env(:ash_dispatch, :user_domain, PerTenant.Domain)

      on_exit(fn ->
        Application.delete_env(:ash_dispatch, :user_module)
        Application.delete_env(:ash_dispatch, :user_resource)
        Application.delete_env(:ash_dispatch, :user_domain)
        Application.put_env(:ash_dispatch, :audiences, [:user, :admin])
      end)

      :ok
    end

    test "matches when the user resource is per tenant" do
      booking = booking!("tenant_a")

      Application.put_env(:ash_dispatch, :audiences,
        user: [:user, reference: booking.reference],
        admin: [:user, reference: "no-such-reference"]
      )

      counters = CounterLoader.load_counters_for_user(booking.id, tenant: "tenant_a")

      # The audience check is the read that had no tenant: it raised, was
      # rescued to `false`, and the counter was dropped from the map entirely.
      assert Map.has_key?(counters, :unread_notifications)
    end

    test "and an audience whose filter does not match the user still counts nothing" do
      booking = booking!("tenant_a")

      Application.put_env(:ash_dispatch, :audiences,
        user: [:user, reference: "no-such-reference"]
      )

      refute Map.has_key?(
               CounterLoader.load_counters_for_user(booking.id, tenant: "tenant_a"),
               :unread_notifications
             )
    end
  end

  describe "a counter whose user_id comes through a relationship" do
    setup do
      parent = self()

      Application.put_env(:ash_dispatch, :counter_broadcast_fn, fn user_id, name, count, meta ->
        send(parent, {:counter, user_id, name, count, meta})
        :ok
      end)

      on_exit(fn -> Application.delete_env(:ash_dispatch, :counter_broadcast_fn) end)
      :ok
    end

    test "loads the relationship in the action's tenant" do
      user_id = Ash.UUID.generate()
      notification = notify!("tenant_a", user_id)

      # Ash records the tenant of the action that produced a record in its
      # metadata, and `Ash.load/3` falls back to it — which is why the missing
      # third argument hid for as long as it did. Stripped here, so the only
      # thing that can carry the tenant into the load is the argument the
      # caller was not passing.
      receipt =
        "tenant_a"
        |> receipt_for!(notification)
        |> Ash.Resource.put_metadata(:tenant, nil)

      :ok =
        CounterHandler.broadcast(
          %Ash.Notifier.Notification{
            data: receipt,
            changeset: %Ash.Changeset{resource: PerTenant.Receipt, tenant: "tenant_a"}
          },
          counter_name: :in_app_receipts,
          resource: PerTenant.Receipt,
          query_filter: [transport: :in_app],
          audience: :user,
          authorize?: false,
          user_id_path: [:notification, :user_id]
        )

      # Without the tenant, `Ash.load(receipt, [:notification], ...)` raises
      # for a `global? false` resource, the user id cannot be resolved and
      # nothing is broadcast at all.
      assert_received {:counter, ^user_id, :in_app_receipts, 1, _meta}
    end

    # The same handler resolves a FILTER-based audience through
    # `Event.Helpers.resolve_recipients_for_audience/2`, which reads the tenant
    # out of the context it is handed — and the context the counter handler
    # built had no tenant in it, so the read raised and the audience resolved
    # to nobody. (Found while re-auditing the call sites for this release; it
    # is a fourth site of the same kind as the three above.)
    test "a filter-based audience resolves its recipients in the action's tenant" do
      booking = booking!("tenant_a")

      Application.put_env(:ash_dispatch, :user_module, PerTenant.Booking)
      Application.put_env(:ash_dispatch, :audiences, guests: [:user, id: booking.id])

      on_exit(fn ->
        Application.delete_env(:ash_dispatch, :user_module)
        Application.put_env(:ash_dispatch, :audiences, [:user, :admin])
      end)

      notification = notify!("tenant_a", booking.id)
      receipt = receipt_for!("tenant_a", notification)

      :ok =
        CounterHandler.broadcast(
          %Ash.Notifier.Notification{
            data: receipt,
            changeset: %Ash.Changeset{resource: PerTenant.Receipt, tenant: "tenant_a"}
          },
          counter_name: :in_app_receipts,
          resource: PerTenant.Receipt,
          query_filter: [transport: :in_app],
          audience: :guests,
          authorize?: false
        )

      booking_id = booking.id
      assert_received {:counter, ^booking_id, :in_app_receipts, _count, _meta}
    end
  end

  defp notify!(tenant, user_id) do
    PerTenant.Notification
    |> Ash.Changeset.for_create(:create, %{
      user_id: user_id,
      event_id: "pt_meeting.updated",
      title: "Meeting",
      message: "moved"
    })
    |> Ash.Changeset.set_tenant(tenant)
    |> Ash.create!(authorize?: false)
  end

  defp receipt_for!(tenant, notification) do
    PerTenant.Receipt
    |> Ash.Changeset.for_create(
      :create,
      %{
        event_id: "pt_meeting.updated",
        transport: :in_app,
        audience: :user,
        recipient: "someone@example.com",
        notification_id: notification.id
      },
      skip_unknown_inputs: [:notification_id]
    )
    |> Ash.Changeset.set_tenant(tenant)
    |> Ash.create!(authorize?: false)
  end
end
