defmodule AshDispatch.Phoenix.LiveViewTest do
  @moduledoc """
  `AshDispatch.Phoenix.LiveView`: the on_mount hook subscribes to the
  user's topic, keeps the unread count in an assign, and handles the
  notification broadcasts in a `handle_info` hook — no JavaScript client.

  Driven with a bare socket rather than a running endpoint: what is under
  test is the hook's contract with LiveView (assigns, the lifecycle hook,
  `{:cont, _}` / `{:halt, _}`), not LiveView itself.
  """
  use AshDispatch.Test.InboxCase, async: false

  alias AshDispatch.Helpers.NotificationLoader
  alias AshDispatch.Phoenix.LiveView, as: Hook
  alias Phoenix.LiveView.Socket

  defmodule PlainView do
    @moduledoc false
  end

  defmodule ReactingView do
    @moduledoc false
    def handle_notification(event, payload, socket) do
      send(self(), {:view_saw, event, payload})
      {:noreply, Phoenix.Component.assign(socket, :last_event, event)}
    end
  end

  defmodule HaltingView do
    @moduledoc false
    def handle_notification(_event, _payload, socket), do: {:halt, socket}
  end

  defmodule BroadcastOnlyPubSub do
    @moduledoc false
    def broadcast(_topic, _event, _payload), do: :ok
  end

  defp socket(assigns, opts \\ []) do
    %Socket{
      assigns: Map.put(assigns, :__changed__, %{}),
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}},
      transport_pid: if(Keyword.get(opts, :connected?, true), do: self()),
      view: Keyword.get(opts, :view, PlainView)
    }
  end

  defp notify!(user, attrs \\ %{}) do
    Notification
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{user_id: user.id, title: "Hello", message: "World"}, attrs)
    )
    |> Ash.create!(authorize?: false)
  end

  defp broadcast(topic, event, payload \\ %{}) do
    %Phoenix.Socket.Broadcast{topic: topic, event: event, payload: payload}
  end

  defp hooks(socket), do: socket.private.lifecycle.handle_info

  describe "on_mount" do
    test "assigns the unread count, subscribes and attaches the handle_info hook" do
      anna = user("anna")
      notify!(anna)
      notify!(anna)

      assert {:cont, socket} =
               Hook.on_mount(:notifications, %{}, %{}, socket(%{current_user: anna}))

      assert socket.assigns.unread_notifications == 2
      topic = "user:#{anna.id}"
      assert_received {:subscribed, ^topic}
      assert [%{id: :ash_dispatch_notifications}] = hooks(socket)
    end

    test "does not subscribe before the socket is connected" do
      anna = user("anna")

      assert {:cont, socket} =
               Hook.on_mount(
                 :notifications,
                 %{},
                 %{},
                 socket(%{current_user: anna}, connected?: false)
               )

      assert socket.assigns.unread_notifications == 0
      refute_received {:subscribed, _}
    end

    test "without a user: zero, and nothing attached" do
      assert {:cont, socket} = Hook.on_mount(:notifications, %{}, %{}, socket(%{}))

      assert socket.assigns.unread_notifications == 0
      assert hooks(socket) == []
      refute_received {:subscribed, _}
    end

    test "a pubsub module without subscribe/1 does not crash the mount" do
      Application.put_env(:ash_dispatch, :pubsub_module, BroadcastOnlyPubSub)
      anna = user("anna")
      notify!(anna)

      assert {:cont, socket} =
               Hook.on_mount(:notifications, %{}, %{}, socket(%{current_user: anna}))

      assert socket.assigns.unread_notifications == 1
    end

    test "user: [] is no user, not the whole assigns map" do
      assert {:cont, socket} =
               Hook.on_mount({:notifications, user: []}, %{}, %{}, socket(%{id: "dom-id"}))

      assert hooks(socket) == []
      refute_received {:subscribed, _}
    end

    test "options: a user path, a tenant path and the assign's name" do
      anna = user("anna")
      notify!(anna, %{tenant: "org_1"})
      notify!(anna, %{tenant: "org_2"})

      assigns = %{current_scope: %{user: anna, organisation: %{id: "org_1"}}}

      assert {:cont, socket} =
               Hook.on_mount(
                 {:notifications,
                  user: [:current_scope, :user],
                  tenant: [:current_scope, :organisation, :id],
                  assign: :bell},
                 %{},
                 %{},
                 socket(assigns)
               )

      assert socket.assigns.bell == 1
    end
  end

  describe "the handle_info hook" do
    setup do
      anna = user("anna")
      {:cont, socket} = Hook.on_mount(:notifications, %{}, %{}, socket(%{current_user: anna}))
      %{anna: anna, socket: socket, topic: "user:#{anna.id}"}
    end

    test "a new notification: counted again, and halted", %{anna: anna} = ctx do
      notify!(anna)

      assert {:halt, socket} =
               Hook.handle_info(broadcast(ctx.topic, "new_notification"), ctx.socket)

      assert socket.assigns.unread_notifications == 1
    end

    test "read in another tab: counted again", %{anna: anna} = ctx do
      notification = notify!(anna)
      {:halt, socket} = Hook.handle_info(broadcast(ctx.topic, "new_notification"), ctx.socket)
      assert socket.assigns.unread_notifications == 1

      {:ok, _} =
        AshDispatch.Helpers.NotificationLoader.mark_as_read(notification.id, actor: anna)

      assert {:halt, socket} =
               Hook.handle_info(broadcast(ctx.topic, "notifications_read"), socket)

      assert socket.assigns.unread_notifications == 0
    end

    test "the LiveView's handle_notification/3 is called after the count", %{anna: anna} = ctx do
      notify!(anna)
      socket = %{ctx.socket | view: ReactingView}

      assert {:halt, socket} =
               Hook.handle_info(broadcast(ctx.topic, "new_notification", %{id: "n1"}), socket)

      assert_received {:view_saw, "new_notification", %{id: "n1"}}
      assert socket.assigns.last_event == "new_notification"
      assert socket.assigns.unread_notifications == 1
    end

    test "a handle_notification/3 that answers {:halt, socket} is accepted", ctx do
      socket = %{ctx.socket | view: HaltingView}

      assert {:halt, %Socket{}} =
               Hook.handle_info(broadcast(ctx.topic, "new_notification"), socket)
    end

    test "anything else passes through to the LiveView", ctx do
      assert {:cont, _} = Hook.handle_info(:tick, ctx.socket)

      assert {:cont, _} =
               Hook.handle_info(broadcast("user:someone-else", "new_notification"), ctx.socket)

      assert {:cont, _} = Hook.handle_info(broadcast(ctx.topic, "counter_updated"), ctx.socket)
    end

    test "end to end: a dispatch reaches the count", %{anna: anna} = ctx do
      _ = broadcasts()
      assert {:ok, _} = send_event(:updated, [anna])

      assert [{topic, event, payload}] = broadcasts()
      assert topic == ctx.topic

      assert {:halt, socket} =
               Hook.handle_info(broadcast(topic, event, payload), ctx.socket)

      assert socket.assigns.unread_notifications == 1
    end
  end

  describe "helpers" do
    test "mark_all_as_read/1 marks as the user and zeroes the count" do
      [anna, bo] = [user("anna"), user("bo")]
      notify!(anna)
      notify!(bo)

      {:cont, socket} = Hook.on_mount(:notifications, %{}, %{}, socket(%{current_user: anna}))
      assert socket.assigns.unread_notifications == 1

      assert {:ok, socket} = Hook.mark_all_as_read(socket)
      assert socket.assigns.unread_notifications == 0
      assert Notification.unread_count!(actor: bo) == 1
    end

    test "mark_all_as_read/1 in a tenant's inbox leaves the other tenants' alone" do
      anna = user("anna")
      notify!(anna, %{tenant: "org_1"})
      notify!(anna, %{tenant: "org_2"})
      notify!(anna)

      assigns = %{current_user: anna, org: %{id: "org_1"}}

      {:cont, socket} =
        Hook.on_mount({:notifications, tenant: [:org, :id]}, %{}, %{}, socket(assigns))

      # org_1's notification and the one without a tenant.
      assert socket.assigns.unread_notifications == 2

      assert {:ok, socket} = Hook.mark_all_as_read(socket)
      assert socket.assigns.unread_notifications == 0
      assert NotificationLoader.unread_count(actor: anna, tenant: "org_2") == {:ok, 1}
    end

    test "refresh/1 reads the count again" do
      anna = user("anna")
      {:cont, socket} = Hook.on_mount(:notifications, %{}, %{}, socket(%{current_user: anna}))
      notify!(anna)

      assert Hook.refresh(socket).assigns.unread_notifications == 1
    end
  end
end
