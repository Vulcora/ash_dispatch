# LiveView Notifications

A notification bell in a Phoenix LiveView app, live, without a JavaScript
client: `AshDispatch.Phoenix.LiveView` is an `on_mount` hook that subscribes
each LiveView to the signed-in user's topic and keeps their unread count in an
assign. (For a React or other JS frontend, see
[Phoenix Channel Integration](phoenix-integration.md) and the
[TypeScript SDK](typescript-sdk.md) instead.)

## What you need

- A notification resource on `AshDispatch.Resources.Notification.Base`, and
  `config :ash_dispatch, notification_resource: MyApp.Notifications.Notification`
- The endpoint as the pubsub module — the in-app transport broadcasts through
  it and the hook subscribes through it:

  ```elixir
  config :ash_dispatch, pubsub_module: MyAppWeb.Endpoint
  ```

- Events with an `:in_app` channel, e.g.

  ```elixir
  event :invited,
    trigger_on: :create,
    metadata: [category: :meetings],
    channels: [[transport: :in_app, audience: :user, exclude_actor: true]]
  ```

## 1. Mount the hook

In the router, after the hook that assigns the user:

```elixir
live_session :app,
  on_mount: [
    {MyAppWeb.UserAuth, :ensure_authenticated},
    {AshDispatch.Phoenix.LiveView, :notifications}
  ] do
  live "/", HomeLive
  live "/notifications", NotificationsLive
end
```

Every LiveView in the session now has `@unread_notifications`:

```heex
<.link navigate={~p"/notifications"} class="relative">
  <.icon name="hero-bell" />
  <span :if={@unread_notifications > 0} class="badge">{@unread_notifications}</span>
</.link>
```

When a notification is created for the user, or read in another tab, the
count is read again and the assign changes. The hook handles those messages
itself (a `handle_info` lifecycle hook), so no LiveView needs a
`handle_info/2` clause for them.

### Options

```elixir
{AshDispatch.Phoenix.LiveView,
 {:notifications,
  user: [:current_scope, :user],            # where the user is (default :current_user)
  tenant: [:current_scope, :organisation, :id], # count only this tenant's
  assign: :bell}}                           # the assign (default :unread_notifications)
```

`:user` and `:tenant` are an assign name or a path into the assigns.

## 2. React in a LiveView

A LiveView that wants more than the count — a toast, a live list — defines
`handle_notification/3`. It is called after the count is updated, with the
event and the broadcast payload:

```elixir
defmodule MyAppWeb.NotificationsLive do
  use MyAppWeb, :live_view

  alias MyApp.Notifications.Notification

  def mount(_params, _session, socket) do
    notifications = Notification.list_for_user!(socket.assigns.current_user.id, actor: socket.assigns.current_user)
    {:ok, stream(socket, :notifications, notifications)}
  end

  def handle_notification("new_notification", notification, socket) do
    {:noreply,
     socket
     |> stream_insert(:notifications, notification, at: 0)
     |> put_flash(:info, notification.title)}
  end

  def handle_notification(_event, _payload, socket), do: {:noreply, socket}

  def handle_event("read_all", _params, socket) do
    case AshDispatch.Phoenix.LiveView.mark_all_as_read(socket) do
      {:ok, socket} -> {:noreply, socket}
      {:error, _reason, socket} -> {:noreply, put_flash(socket, :error, "Could not mark as read")}
    end
  end
end
```

The events are:

| event | when | payload |
| --- | --- | --- |
| `"new_notification"` | the in-app transport created one | the serialized notification (`id`, `title`, `message`, `category`, `actionUrl`, …) |
| `"notifications_read"` | `mark_as_read` or `mark_all_as_read` ran | `%{userId: id}` |

## 3. The resource side

`Notification.Base` (0.9.0) has what a notification centre needs:

| | |
| --- | --- |
| `category`, `tenant` | filed by the in-app transport from the event's `metadata: [category: ...]` and `context.tenant` |
| `seen_at` | set by `:mark_as_seen` / `:mark_all_as_seen` ("opened the list") and by `:mark_as_read` |
| `archived_at` | `:archive` / `:unarchive`; archived notifications are not unread |
| `:unread` | read action: the actor's unread, not archived notifications (optional `tenant` argument) |
| `:unread_count` | generic action returning the actor's unread count |
| `:mark_all_as_read` | without `user_id` it marks the actor's own feed; with it, only the actor's |

```elixir
Notification.unread_count!(actor: user)
Notification.mark_all_as_read(nil, actor: user)
AshDispatch.Helpers.NotificationLoader.unread_count(actor: user, tenant: org)
```

Notifications are per user: every read and update is the actor's own, and a
consumer's policies can only restrict further.

## Testing

The hook is plain functions over a socket, so a test can drive it without an
endpoint:

```elixir
socket = %Phoenix.LiveView.Socket{
  assigns: %{__changed__: %{}, current_user: user},
  private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}},
  transport_pid: self()
}

{:cont, socket} = AshDispatch.Phoenix.LiveView.on_mount(:notifications, %{}, %{}, socket)
socket.assigns.unread_notifications
```

With `Phoenix.LiveViewTest`, send the broadcast to the view process —
`send(view.pid, %Phoenix.Socket.Broadcast{topic: "user:#{user.id}", event: "new_notification", payload: %{}})`
— and assert on the rendered count.
