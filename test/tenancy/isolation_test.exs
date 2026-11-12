defmodule AshDispatch.Tenancy.IsolationTest do
  @moduledoc """
  Two tenants, and nothing of one reachable from the other through anything the
  library offers a host: the receipts, the notifications, the preferences, the
  counts, a preview of a record, a manual trigger.

  The interesting half is not that each tenant's own call works — it is that
  the call made *in the other tenant* comes back empty rather than with
  somebody else's rows.
  """
  use AshDispatch.Test.PerTenantCase, async: false

  alias AshDispatch.Helpers.NotificationLoader
  alias AshDispatch.Preview
  alias AshDispatch.UserPreference.Resource, as: Preferences

  @moduletag :postgres
  @moduletag :capture_log

  setup do
    kim = user("kim")

    {:ok, _} = send_event(:updated, "tenant_a", [kim])

    %{kim: kim}
  end

  describe "notifications" do
    test "the list is per tenant", %{kim: kim} do
      assert [%{title: "pt_meeting.updated"}] =
               NotificationLoader.load_recent(kim.id, tenant: "tenant_a")

      assert NotificationLoader.load_recent(kim.id, tenant: "tenant_b") == []
    end

    test "the unread count is per tenant", %{kim: kim} do
      assert {:ok, 1} = NotificationLoader.unread_count(actor: %{id: kim.id}, tenant: "tenant_a")
      assert {:ok, 0} = NotificationLoader.unread_count(actor: %{id: kim.id}, tenant: "tenant_b")
    end

    test "marking all as read in one tenant leaves the other's unread", %{kim: kim} do
      {:ok, _} = send_event(:updated, "tenant_b", [kim])

      assert {:ok, _} =
               NotificationLoader.mark_all_as_read(kim.id,
                 actor: %{id: kim.id},
                 tenant: "tenant_b"
               )

      assert {:ok, 1} = NotificationLoader.unread_count(actor: %{id: kim.id}, tenant: "tenant_a")
      assert {:ok, 0} = NotificationLoader.unread_count(actor: %{id: kim.id}, tenant: "tenant_b")
    end

    test "a notification cannot be marked as read from the wrong tenant", %{kim: kim} do
      [notification] = notifications("tenant_a")

      assert {:error, _} =
               NotificationLoader.mark_as_read(notification.id,
                 actor: %{id: kim.id},
                 tenant: "tenant_b"
               )

      assert {:ok, _} =
               NotificationLoader.mark_as_read(notification.id,
                 actor: %{id: kim.id},
                 tenant: "tenant_a"
               )
    end
  end

  describe "preferences" do
    test "a settings screen shows one tenant's answers", %{kim: kim} do
      put_preference!("tenant_a", %{
        user_id: kim.id,
        event_id: "pt_meeting.updated",
        transport: :in_app,
        enabled: false
      })

      in_a = settings_for(kim.id, "tenant_a")
      in_b = settings_for(kim.id, "tenant_b")

      assert %{enabled: false, source: :user} = in_a
      assert %{enabled: true, source: :event} = in_b
    end

    test "put/3 and clear/2 touch one tenant's rows only", %{kim: kim} do
      scope = %{user_id: kim.id, event_id: "pt_meeting.updated", transport: :in_app}
      # Their own row, so the actor is the person: `PreferenceWriter` refuses a
      # write with no actor, which is the behaviour this release leaves alone.
      as_kim = [actor: %{id: kim.id}]

      assert {:ok, _} = Preferences.put(Map.put(scope, :tenant, "tenant_a"), false, as_kim)

      assert length(preferences("tenant_a")) == 1
      assert preferences("tenant_b") == []

      # Clearing the other tenant's row is a no-op, not a reset of this one.
      assert :ok = Preferences.clear(Map.put(scope, :tenant, "tenant_b"), as_kim)
      assert length(preferences("tenant_a")) == 1

      assert :ok = Preferences.clear(Map.put(scope, :tenant, "tenant_a"), as_kim)
      assert preferences("tenant_a") == []
    end
  end

  describe "receipts" do
    test "are only ever read from their own schema", %{kim: _kim} do
      assert [receipt] = receipts("tenant_a")
      assert receipts("tenant_b") == []

      assert {:error, _} =
               Ash.get(PerTenant.Receipt, receipt.id, authorize?: false, tenant: "tenant_b")
    end
  end

  defp settings_for(user_id, tenant) do
    Preferences.settings(user_id, tenant)
    |> Enum.find(&(&1.event_id == "pt_meeting.updated" and &1.transport == :in_app))
  end

  describe "a preview of a record" do
    test "reads the record from the tenant it is asked for" do
      booking = booking!("tenant_a", %{reference: "B-ONLY-IN-A"})

      assert {:ok, [rendered]} =
               Preview.render("pt_booking.confirmed", {:record, booking.id}, tenant: "tenant_a")

      assert rendered.error == nil
      assert rendered.title == "Booking B-ONLY-IN-A confirmed"

      # The same id, asked for in the other tenant: nothing to render from.
      assert {:error, _} =
               Preview.render("pt_booking.confirmed", {:record, booking.id}, tenant: "tenant_b")
    end

    test "and a dispatch of that record delivers inside the tenant" do
      booking = booking!("tenant_a")

      assert {:ok, _} =
               AshDispatch.Dispatcher.dispatch(
                 "pt_booking.confirmed",
                 %{booking: booking},
                 %{},
                 tenant: "tenant_a"
               )

      assert Enum.any?(receipts("tenant_a"), &(&1.event_id == "pt_booking.confirmed"))
      refute Enum.any?(receipts("tenant_b"), &(&1.event_id == "pt_booking.confirmed"))
    end
  end
end
