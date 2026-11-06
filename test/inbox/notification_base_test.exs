defmodule AshDispatch.Inbox.NotificationBaseTest do
  @moduledoc """
  The 0.9.0 additions to `AshDispatch.Resources.Notification.Base`: category,
  tenant, `seen_at`, `archived_at`, the `:unread` read and `:unread_count`,
  and a `mark_all_as_read` that carries the actor.

  `NotificationLoader.mark_all_as_read/2` dropped its `:actor` until 0.9.0,
  so the action's policy (the user must be the actor) refused every call.
  """
  use AshDispatch.Test.InboxCase, async: false

  alias AshDispatch.Helpers.NotificationLoader

  defp notify!(user, attrs \\ %{}) do
    Notification
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{user_id: user.id, title: "Hello", message: "World"}, attrs)
    )
    |> Ash.create!(authorize?: false)
  end

  defp reload(notification), do: Ash.get!(Notification, notification.id, authorize?: false)

  describe "unread_count" do
    test "counts the actor's unread, not archived notifications" do
      [anna, bo] = [user("anna"), user("bo")]

      notify!(anna)
      notify!(anna)

      notify!(anna)
      |> Ash.Changeset.for_update(:mark_as_read, %{})
      |> Ash.update!(authorize?: false)

      notify!(anna) |> Ash.Changeset.for_update(:archive, %{}) |> Ash.update!(authorize?: false)
      notify!(bo)

      assert Notification.unread_count!(actor: anna) == 2
      assert NotificationLoader.unread_count(actor: anna) == {:ok, 2}
      assert NotificationLoader.unread_count(actor: bo) == {:ok, 1}
      assert length(Notification.unread!(actor: anna)) == 2
    end

    test "filters by tenant when asked" do
      anna = user("anna")
      notify!(anna, %{tenant: "org_1"})
      notify!(anna, %{tenant: "org_2"})

      assert NotificationLoader.unread_count(actor: anna, tenant: "org_1") == {:ok, 1}
      assert NotificationLoader.unread_count(actor: anna) == {:ok, 2}
    end

    test "a notification without a tenant is counted in every tenant" do
      anna = user("anna")
      notify!(anna, %{tenant: "org_1"})
      notify!(anna, %{tenant: "org_2"})
      # From before 0.9.0, or sent without :tenant.
      notify!(anna)

      assert NotificationLoader.unread_count(actor: anna, tenant: "org_1") == {:ok, 2}
      assert NotificationLoader.unread_count(actor: anna, tenant: "org_2") == {:ok, 2}
      assert NotificationLoader.unread_count(actor: anna) == {:ok, 3}
    end

    test "needs an actor" do
      assert {:error, %Ash.Error.Forbidden{}} = NotificationLoader.unread_count(actor: nil)
    end
  end

  describe "mark_all_as_read" do
    test "NotificationLoader passes the actor on (the 0.8 bug)" do
      anna = user("anna")
      notify!(anna)
      notify!(anna)

      assert {:ok, _} = NotificationLoader.mark_all_as_read(anna.id, actor: anna)
      assert Notification.unread_count!(actor: anna) == 0
    end

    test "without user_id it marks the actor's own feed" do
      [anna, bo] = [user("anna"), user("bo")]
      notify!(anna)
      notify!(bo)

      assert {:ok, _} = Notification.mark_all_as_read(nil, actor: anna)

      assert Notification.unread_count!(actor: anna) == 0
      assert Notification.unread_count!(actor: bo) == 1
    end

    test "with :tenant only that tenant's and the untenanted ones" do
      anna = user("anna")
      notify!(anna, %{tenant: "org_1"})
      notify!(anna, %{tenant: "org_2"})
      notify!(anna)

      assert {:ok, _} =
               NotificationLoader.mark_all_as_read(anna.id, actor: anna, tenant: "org_1")

      assert NotificationLoader.unread_count(actor: anna) == {:ok, 1}
      assert NotificationLoader.unread_count(actor: anna, tenant: "org_2") == {:ok, 1}
    end

    test "someone else's feed is forbidden" do
      [anna, bo] = [user("anna"), user("bo")]
      notify!(bo)

      assert {:error, %Ash.Error.Forbidden{}} =
               NotificationLoader.mark_all_as_read(bo.id, actor: anna)

      assert Notification.unread_count!(actor: bo) == 1
    end

    test "tells the user's other screens, once" do
      anna = user("anna")
      notify!(anna)
      notify!(anna)
      _ = broadcasts()

      assert {:ok, _} = Notification.mark_all_as_read(nil, actor: anna)

      topic = "user:#{anna.id}"
      assert [{^topic, "notifications_read", %{userId: _}}] = broadcasts()
    end
  end

  describe "mark_as_read, seen and archive" do
    test "reading sets seen_at too, and broadcasts" do
      anna = user("anna")
      notification = notify!(anna)
      _ = broadcasts()

      {:ok, read} = NotificationLoader.mark_as_read(notification.id, actor: anna)

      assert read.read
      assert read.seen_at
      assert [{_topic, "notifications_read", _}] = broadcasts()
    end

    test "seen_at keeps the first time" do
      anna = user("anna")
      notification = notify!(anna)

      seen =
        notification
        |> Ash.Changeset.for_update(:mark_as_seen, %{})
        |> Ash.update!(actor: anna)

      read =
        seen |> Ash.Changeset.for_update(:mark_as_read, %{}) |> Ash.update!(actor: anna)

      assert read.seen_at == seen.seen_at
    end

    test "mark_all_as_seen and archive" do
      anna = user("anna")
      one = notify!(anna)
      two = notify!(anna)

      assert {:ok, _} = Notification.mark_all_as_seen(actor: anna)
      assert reload(one).seen_at && reload(two).seen_at
      refute reload(one).read

      archived = one |> Ash.Changeset.for_update(:archive, %{}) |> Ash.update!(actor: anna)
      assert archived.archived_at
      assert Notification.unread_count!(actor: anna) == 1

      archived |> Ash.Changeset.for_update(:unarchive, %{}) |> Ash.update!(actor: anna)
      assert Notification.unread_count!(actor: anna) == 2
    end
  end

  describe "the in-app transport" do
    test "files the notification under category and tenant, and broadcasts them" do
      anna = user("anna")
      _ = broadcasts()

      assert {:ok, _} = send_event(:updated, [anna], tenant: "org_1")

      assert [%{category: "meetings", tenant: "org_1"}] = notifications_for(anna.id)

      topic = "user:#{anna.id}"
      assert [{^topic, "new_notification", %{category: "meetings"}}] = broadcasts()
    end
  end
end
