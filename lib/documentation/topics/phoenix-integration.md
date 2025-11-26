# Phoenix Channel Integration

AshDispatch provides **zero-configuration helpers** to integrate real-time notifications and counter updates with Phoenix Channels. These helpers eliminate boilerplate and provide a best-practice implementation out of the box.

## Quick Start: UserChannel Macro (Recommended)

The fastest way to set up real-time updates - just 3 lines of code:

```elixir
# lib/my_app_web/channels/user_channel.ex
defmodule MyAppWeb.UserChannel do
  use AshDispatch.Phoenix.UserChannel,
    endpoint: MyAppWeb.Endpoint
end
```

Add to your socket:

```elixir
# lib/my_app_web/user_socket.ex
channel "user:*", MyAppWeb.UserChannel
```

**That's it!** You get:
- `join/3` with authorization
- `handle_info(:after_join, ...)` with initial state
- `handle_in("refresh_counters", ...)` for client requests
- `broadcast_notification/2`, `broadcast_counter/4`, `broadcast_counters/2`

All callbacks are `defoverridable` so you can customize as needed.

### Customizing the Macro

Override any callback by defining it in your module:

```elixir
defmodule MyAppWeb.UserChannel do
  use AshDispatch.Phoenix.UserChannel,
    endpoint: MyAppWeb.Endpoint

  # Custom join with logging
  def join("user:" <> user_id, payload, socket) do
    Logger.info("User #{user_id} joining channel")

    if socket.assigns.user_id == user_id do
      send(self(), :after_join)
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  # Add custom message handlers
  def handle_in("custom_action", payload, socket) do
    # Your custom logic
    {:reply, :ok, socket}
  end
end
```

---

## What You Need to Write

### Backend (Elixir)

| File | Purpose | AshDispatch Provides |
|------|---------|---------------------|
| `user_channel.ex` | Phoenix channel for real-time updates | **UserChannel macro** (3 lines) or helpers |
| `user_socket.ex` | WebSocket authentication | - (standard Phoenix) |

**3 lines** with UserChannel macro, or **~50-80 lines** with manual helper usage.

### Frontend (TypeScript/React)

| File | Purpose | Generated/Manual |
|------|---------|------------------|
| `ash-dispatch/` | Complete SDK | **Generated** by `mix ash_dispatch.gen` |
| `counters.ts` | Counter types & metadata | **Generated** by `mix ash_dispatch.gen` |

Run `mix ash_dispatch.gen` to generate the complete TypeScript SDK with hooks, stores, and types. See [Generator](generator.md) for details.

### Architecture: Two Stores, One Source of Truth

```
┌─────────────────┐     WebSocket      ┌──────────────────┐
│  Counter Store  │ ←───────────────── │  AshDispatch     │
│ (all counters)  │   counter_updated  │  Broadcasting    │
└────────┬────────┘                    └──────────────────┘
         │
         │ read from
         ▼
┌─────────────────┐
│ useNotifications│ ← unreadCount from counter store
│ useCounters     │ ← all counters from counter store
└─────────────────┘
```

**Key insight:** The counter store is the **single source of truth** for all real-time counts. Feature hooks (like `useNotifications`) read counts from the counter store, not their own state.

See [Counter Store as Single Source of Truth](counter-broadcasting.md#counter-store-as-single-source-of-truth) for details.

---

## Quick Start

### 1. Configure Counter Broadcasting

Tell AshDispatch which function to call when broadcasting counter updates:

```elixir
# config/config.exs
config :ash_dispatch,
  counter_broadcast_fn: {MyAppWeb.UserChannel, :broadcast_counter}
```

### 2. Setup Your UserChannel

Use the helper modules for zero-boilerplate channel implementation:

```elixir
defmodule MyAppWeb.UserChannel do
  use MyAppWeb, :channel

  # Import all helper modules
  alias AshDispatch.Helpers.{ChannelState, CounterLoader, NotificationLoader}

  @impl true
  def join("user:" <> user_id, _payload, socket) do
    if socket.assigns.user_id == user_id do
      send(self(), :after_join)
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    # Single line to load complete initial state (counters + notifications in parallel!)
    initial_state = ChannelState.build(socket.assigns.user_id)

    push(socket, "initial_state", initial_state)
    {:noreply, socket}
  end

  # Client requests to refresh counters
  @impl true
  def handle_in("refresh_counters", _payload, socket) do
    counters = CounterLoader.load_counters_for_user(socket.assigns.user_id)
    {:reply, {:ok, %{counters: counters}}, socket}
  end

  # Client marks notification as read
  @impl true
  def handle_in("mark_notification_read", %{"id" => id}, socket) do
    case NotificationLoader.mark_as_read(id, actor: socket.assigns.current_user) do
      {:ok, _} -> {:reply, :ok, socket}
      {:error, %Ash.Error.Forbidden{}} -> {:reply, {:error, %{reason: "unauthorized"}}, socket}
      {:error, error} -> {:reply, {:error, %{reason: inspect(error)}}, socket}
    end
  end

  # Client marks all notifications as read
  @impl true
  def handle_in("mark_all_notifications_read", _payload, socket) do
    user_id = socket.assigns.user_id

    case NotificationLoader.mark_all_as_read(user_id, actor: socket.assigns.current_user) do
      {:ok, %{marked_count: _count}} ->
        broadcast_all_notifications_read(user_id)
        broadcast_counter(user_id, :unread_notifications, 0)
        {:reply, :ok, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: "failed", details: inspect(reason)}}, socket}
    end
  end

  ## Broadcaster functions (called by AshDispatch)

  def broadcast_notification(user_id, notification) do
    MyAppWeb.Endpoint.broadcast("user:#{user_id}", "new_notification", notification)
  end

  def broadcast_counter(user_id, counter_name, value, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    MyAppWeb.Endpoint.broadcast("user:#{user_id}", "counter_updated", %{
      counter: counter_name,
      value: value,
      metadata: metadata
    })
  end

  defp broadcast_all_notifications_read(user_id) do
    MyAppWeb.Endpoint.broadcast("user:#{user_id}", "all_notifications_read", %{})
  end
end
```

**That's it!** About 50 lines of code for a complete real-time notification and counter system.

---

## Helper Modules

### ChannelState - Complete Initial State

**Module:** `AshDispatch.Helpers.ChannelState`

Builds the complete initial state when users connect to your channel. Loads counters and notifications **in parallel** for optimal performance.

#### Basic Usage

```elixir
def handle_info(:after_join, socket) do
  user_id = socket.assigns.user_id

  # Single call loads everything
  initial_state = ChannelState.build(user_id)
  # => %{
  #   "counters" => %{"pending_orders" => 5, "cart_items" => 3},
  #   "notifications" => [%{id: "...", title: "...", ...}, ...]
  # }

  push(socket, "initial_state", initial_state)
  {:noreply, socket}
end
```

#### Custom Options

```elixir
# Limit number of notifications
ChannelState.build(user_id, notification_limit: 10)

# Custom notification serializer
ChannelState.build(user_id,
  notification_serializer: &MyApp.serialize_notification/1
)

# Load from specific domains only
ChannelState.build(user_id,
  counter_domains: [MyApp.Orders, MyApp.Tickets]
)

# Disable parallel loading (for debugging)
ChannelState.build(user_id, parallel: false)
```

#### Loading Only Counters or Notifications

Use the underlying loaders directly when you only need one type:

```elixir
alias AshDispatch.Helpers.{CounterLoader, NotificationLoader}

# Counters only
counters = CounterLoader.load_counters_for_user(user_id)
# => %{pending_orders: 5, cart_items: 3}

# Notifications only
notifications = NotificationLoader.load_recent(user_id, limit: 20)
# => [%{id: "...", ...}, ...]
```

#### Performance

- **Parallel Loading**: Uses `Task.async` to load counters and notifications simultaneously
- **Auto-Discovery**: Counters are discovered from DSL, no manual configuration
- **Efficient Queries**: Only loads what's needed for the specific user

---

### CounterLoader - Auto-Discovery Counter Loading

**Module:** `AshDispatch.Helpers.CounterLoader`

Automatically discovers counter definitions from your resource DSL and loads their current values.

#### Basic Usage

```elixir
# Load all counters for a user
counters = CounterLoader.load_counters_for_user(user_id)
# => %{
#   pending_orders: 5,
#   cart_items: 3,
#   active_tickets: 2
# }
```

#### How It Works

1. **Discovers Resources**: Scans all configured Ash domains
2. **Reads DSL**: Finds all `counters do` blocks in resources
3. **Determines Audiences**: Checks which counters apply to this user (`:user`, `:admin`, etc.)
4. **Executes Queries**: Runs counter queries and returns results

#### Audience Filtering

Automatically filters counters based on user's audiences:

```elixir
# Regular user - gets only :user counters
CounterLoader.load_counters_for_user("user-123")
# => %{pending_orders: 5, cart_items: 3}

# Admin user - gets :user + :admin counters
CounterLoader.load_counters_for_user("admin-456")
# => %{
#   pending_orders: 12,           # :user counter
#   cart_items: 0,                # :user counter
#   admin_pending_reseller_requests: 3  # :admin counter
# }
```

#### Load Admin Counters Only

```elixir
# Load only :admin audience counters
admin_counters = CounterLoader.load_admin_counters()
# => %{admin_pending_reseller_requests: 3, admin_pending_orders: 12}
```

#### Configuration

```elixir
# config/config.exs
config :ash_dispatch,
  domains: [MyApp.Orders, MyApp.Tickets, MyApp.Catalog],
  user_module: MyApp.Accounts.User,
  recipient_filters: [
    audiences: [
      admin: [admin: true],
      partner: [role: :partner]
    ]
  ]
```

---

### NotificationLoader - Notification Management

**Module:** `AshDispatch.Helpers.NotificationLoader`

Handles loading, serializing, and updating notifications with sensible defaults.

#### Load Recent Notifications

```elixir
# Default: 50 most recent
notifications = NotificationLoader.load_recent(user_id)
# => [%{id: "...", title: "...", message: "...", read: false, ...}]

# Custom limit
notifications = NotificationLoader.load_recent(user_id, limit: 10)

# Custom serializer
notifications = NotificationLoader.load_recent(user_id,
  serializer: &MyApp.serialize_notification/1
)
```

#### Mark as Read

```elixir
# Mark single notification as read
case NotificationLoader.mark_as_read(notification_id, actor: current_user) do
  {:ok, notification} -> # Success
  {:error, %Ash.Error.Forbidden{}} -> # Unauthorized
  {:error, reason} -> # Other error
end

# Mark all as read
case NotificationLoader.mark_all_as_read(user_id, actor: current_user) do
  {:ok, %{marked_count: count}} -> # Success, count notifications marked
  {:error, reason} -> # Failed
end
```

#### Default Serialization

The default serializer uses camelCase keys for JavaScript compatibility:

```elixir
%{
  id: "abc-123",
  type: :success,
  title: "Order Created",
  message: "Your order #1234 has been created",
  read: false,
  timestamp: ~U[2025-01-16 10:00:00Z],
  metadata: %{order_id: "1234"},
  actionLabel: "View Order",  # camelCase!
  actionUrl: "/orders/1234"   # camelCase!
}
```

#### Custom Serializer

Provide your own serializer for custom fields or format:

```elixir
defmodule MyApp.NotificationSerializer do
  def serialize(notification) do
    %{
      id: notification.id,
      title: notification.title,
      message: notification.message,
      read: notification.read,
      # Custom fields
      priority: notification.metadata[:priority] || :normal,
      icon: notification_icon(notification.type),
      timestamp: format_timestamp(notification.inserted_at)
    }
  end

  defp notification_icon(:success), do: "check-circle"
  defp notification_icon(:error), do: "alert-circle"
  defp notification_icon(_), do: "info-circle"

  defp format_timestamp(dt), do: DateTime.to_unix(dt)
end

# Use in channel
NotificationLoader.load_recent(user_id,
  serializer: &MyApp.NotificationSerializer.serialize/1
)
```

---

## Complete Example: Production-Ready UserChannel

Here's a complete, production-ready Phoenix Channel using all helpers:

```elixir
defmodule MyAppWeb.UserChannel do
  @moduledoc """
  Central channel for user-specific real-time updates:
  - Notifications (in-app)
  - Real-time counters (cart, tickets, orders, etc.)
  - Other user-specific events

  Uses AshDispatch helpers for zero-boilerplate implementation.
  """
  use MyAppWeb, :channel

  alias AshDispatch.Helpers.{ChannelState, CounterLoader, NotificationLoader}
  require Logger

  @impl true
  def join("user:" <> user_id, _payload, socket) do
    # Verify authorization (token verification in UserSocket)
    if socket.assigns.user_id == user_id do
      # Send initial state after successful join
      send(self(), :after_join)
      {:ok, socket}
    else
      Logger.warning("[UserChannel] Unauthorized join attempt for user:#{user_id}")
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    user_id = socket.assigns.user_id
    Logger.debug("[UserChannel] Loading initial state for user:#{user_id}")

    # Build complete initial state (counters + notifications in parallel)
    initial_state = ChannelState.build(user_id)

    push(socket, "initial_state", initial_state)
    {:noreply, socket}
  end

  ## Client Requests

  @impl true
  def handle_in("refresh_counters", _payload, socket) do
    user_id = socket.assigns.user_id
    counters = CounterLoader.load_counters_for_user(user_id)
    {:reply, {:ok, %{counters: counters}}, socket}
  end

  @impl true
  def handle_in("mark_notification_read", %{"id" => id}, socket) do
    case NotificationLoader.mark_as_read(id, actor: socket.assigns.current_user) do
      {:ok, _notification} ->
        {:reply, :ok, socket}

      {:error, %Ash.Error.Forbidden{}} ->
        Logger.warning("[UserChannel] Unauthorized mark_as_read attempt: #{id}")
        {:reply, {:error, %{reason: "unauthorized"}}, socket}

      {:error, error} ->
        Logger.error("[UserChannel] Failed to mark notification as read: #{inspect(error)}")
        {:reply, {:error, %{reason: "failed"}}, socket}
    end
  end

  @impl true
  def handle_in("mark_all_notifications_read", _payload, socket) do
    user_id = socket.assigns.user_id

    case NotificationLoader.mark_all_as_read(user_id, actor: socket.assigns.current_user) do
      {:ok, %{marked_count: _count}} ->
        # Broadcast to all user's connected clients
        broadcast_all_notifications_read(user_id)
        # Update unread counter
        broadcast_counter(user_id, :unread_notifications, 0)
        {:reply, :ok, socket}

      {:error, reason} ->
        Logger.error("[UserChannel] Failed to mark all as read: #{inspect(reason)}")
        {:reply, {:error, %{reason: "failed"}}, socket}
    end
  end

  ## Broadcaster Functions (called from AshDispatch)

  @doc """
  Broadcast a new notification to a user.
  Called automatically by AshDispatch when notifications are created.
  """
  def broadcast_notification(user_id, notification) do
    MyAppWeb.Endpoint.broadcast("user:#{user_id}", "new_notification", notification)
  end

  @doc """
  Broadcast counter update to a user.
  Called automatically by AshDispatch when counters change.

  Options:
  - `:metadata` - Map with optional `invalidate_queries` list
  """
  def broadcast_counter(user_id, counter_name, value, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    MyAppWeb.Endpoint.broadcast("user:#{user_id}", "counter_updated", %{
      counter: counter_name,
      value: value,
      metadata: metadata
    })
  end

  ## Private Helpers

  defp broadcast_all_notifications_read(user_id) do
    MyAppWeb.Endpoint.broadcast("user:#{user_id}", "all_notifications_read", %{})
  end
end
```

---

## Frontend Integration

### React/TypeScript Example

```typescript
import { Socket, Channel } from "phoenix";

interface Counters {
  pending_orders: number;
  cart_items: number;
  active_tickets: number;
  [key: string]: number;
}

interface Notification {
  id: string;
  type: 'info' | 'success' | 'warning' | 'error';
  title: string;
  message: string;
  read: boolean;
  timestamp: string;
  actionLabel?: string;
  actionUrl?: string;
}

interface InitialState {
  counters: Counters;
  notifications: Notification[];
}

export function useUserChannel(userId: string) {
  const [counters, setCounters] = useState<Counters>({});
  const [notifications, setNotifications] = useState<Notification[]>([]);
  const [channel, setChannel] = useState<Channel | null>(null);

  useEffect(() => {
    // Connect to channel
    const socket = new Socket("/socket", {
      params: { token: getAuthToken() }
    });
    socket.connect();

    const channel = socket.channel(`user:${userId}`, {});

    // Receive initial state
    channel.on("initial_state", (payload: InitialState) => {
      setCounters(payload.counters);
      setNotifications(payload.notifications);
    });

    // Counter updates
    channel.on("counter_updated", (payload: {
      counter: string;
      value: number;
      metadata: { invalidate_queries?: string[] };
    }) => {
      setCounters(prev => ({ ...prev, [payload.counter]: payload.value }));

      // Invalidate related queries
      payload.metadata.invalidate_queries?.forEach(queryKey => {
        queryClient.invalidateQueries([queryKey]);
      });
    });

    // New notifications
    channel.on("new_notification", (notification: Notification) => {
      setNotifications(prev => [notification, ...prev]);

      // Show toast
      toast.success(notification.title, {
        description: notification.message
      });
    });

    // All notifications marked as read
    channel.on("all_notifications_read", () => {
      setNotifications(prev => prev.map(n => ({ ...n, read: true })));
    });

    channel.join()
      .receive("ok", () => console.log("Joined user channel"))
      .receive("error", (err) => console.error("Failed to join", err));

    setChannel(channel);

    return () => {
      channel.leave();
      socket.disconnect();
    };
  }, [userId]);

  // Actions
  const markAsRead = (notificationId: string) => {
    channel?.push("mark_notification_read", { id: notificationId })
      .receive("ok", () => {
        setNotifications(prev =>
          prev.map(n => n.id === notificationId ? { ...n, read: true } : n)
        );
      });
  };

  const markAllAsRead = () => {
    channel?.push("mark_all_notifications_read", {})
      .receive("ok", () => {
        setNotifications(prev => prev.map(n => ({ ...n, read: true })));
      });
  };

  const refreshCounters = () => {
    channel?.push("refresh_counters", {})
      .receive("ok", (resp) => {
        setCounters(resp.counters);
      });
  };

  return {
    counters,
    notifications,
    markAsRead,
    markAllAsRead,
    refreshCounters
  };
}
```

### Usage in Components

```typescript
function Dashboard() {
  const { counters, notifications, markAsRead, markAllAsRead } =
    useUserChannel(currentUser.id);

  return (
    <div>
      {/* Show counters */}
      <Badge>Pending Orders: {counters.pending_orders || 0}</Badge>
      <Badge>Cart Items: {counters.cart_items || 0}</Badge>

      {/* Notification dropdown */}
      <NotificationDropdown
        notifications={notifications}
        onMarkAsRead={markAsRead}
        onMarkAllAsRead={markAllAsRead}
      />
    </div>
  );
}
```

---

## Configuration

### Counter Broadcasting

Configure the function to call when broadcasting counter updates:

```elixir
# config/config.exs
config :ash_dispatch,
  # MFA tuple (recommended - easier to test)
  counter_broadcast_fn: {MyAppWeb.UserChannel, :broadcast_counter}

  # Or function capture
  # counter_broadcast_fn: &MyAppWeb.UserChannel.broadcast_counter/4
```

### Full Configuration Example

```elixir
# config/config.exs
config :ash_dispatch,
  # Required: Ash domains to scan for counters
  domains: [MyApp.Orders, MyApp.Tickets, MyApp.Catalog, MyApp.Accounts],

  # Required: User module for audience checking
  user_module: MyApp.Accounts.User,

  # Required: Counter broadcasting
  counter_broadcast_fn: {MyAppWeb.UserChannel, :broadcast_counter},

  # Optional: Audience filters for counter visibility
  recipient_filters: [
    audiences: [
      admin: [admin: true],
      partner: [role: :partner],
      user: []  # All authenticated users
    ]
  ]
```

---

## Testing

### Test Channel with Helpers

```elixir
defmodule MyAppWeb.UserChannelTest do
  use MyAppWeb.ChannelCase

  alias AshDispatch.Helpers.{ChannelState, CounterLoader, NotificationLoader}

  setup do
    user = build(:user) |> create!()
    {:ok, socket} = connect(MyAppWeb.UserSocket, %{"token" => user.token})
    {:ok, _, socket} = subscribe_and_join(socket, MyAppWeb.UserChannel, "user:#{user.id}")

    %{socket: socket, user: user}
  end

  test "sends initial state on join", %{user: user} do
    # Initial state pushed automatically
    assert_push "initial_state", %{
      "counters" => counters,
      "notifications" => notifications
    }

    assert is_map(counters)
    assert is_list(notifications)
  end

  test "refreshes counters on request", %{socket: socket} do
    ref = push(socket, "refresh_counters", %{})
    assert_reply ref, :ok, %{counters: counters}

    assert is_map(counters)
  end

  test "marks notification as read", %{socket: socket, user: user} do
    # Create notification
    notification = build(:notification, %{user_id: user.id}) |> create!()

    ref = push(socket, "mark_notification_read", %{"id" => notification.id})
    assert_reply ref, :ok, %{}

    # Verify marked as read
    notification = reload!(notification)
    assert notification.read == true
  end
end
```

### Mock Counter Broadcast in Tests

```elixir
# config/test.exs
config :ash_dispatch,
  counter_broadcast_fn: {MyAppTest.MockCounterBroadcaster, :broadcast}

# test/support/mock_counter_broadcaster.ex
defmodule MyAppTest.MockCounterBroadcaster do
  def broadcast(user_id, counter_name, value, opts) do
    # Send to test process for assertions
    send(self(), {:counter_broadcast, user_id, counter_name, value, opts})
    :ok
  end
end

# In tests
test "broadcasts counter update" do
  # Trigger action that updates counter...

  assert_received {:counter_broadcast, user_id, :pending_orders, 5, _opts}
end
```

---

## Performance Optimization

### Parallel Loading

The `ChannelState` module loads counters and notifications in parallel by default:

```elixir
# Automatic parallel loading
ChannelState.build(user_id)

# Disable for debugging
ChannelState.build(user_id, parallel: false)
```

### Counter Caching

For frequently-accessed counters, consider caching at the database level:

```elixir
# In resource
counters do
  counter :pending_orders,
    trigger_on: [:create, :complete, :cancel],
    counter_name: :pending_orders,
    query_filter: [status: :pending],
    audience: :user,
    invalidates: ["orders"]
end

# Add database index for fast counting
create index(:orders, [:user_id, :status])
```

### Reduce Notification Payload

Load fewer notifications on initial join:

```elixir
# Default: 50 notifications
ChannelState.build(user_id)

# Reduced: 10 notifications
ChannelState.build(user_id, notification_limit: 10)
```

---

## Troubleshooting

### "No counter_broadcast_fn configured"

**Problem:** Warning logged when counter updates.

**Solution:**
```elixir
config :ash_dispatch,
  counter_broadcast_fn: {MyAppWeb.UserChannel, :broadcast_counter}
```

### "Failed to load counters"

**Problem:** Error when loading counters.

**Causes:**
1. Missing `:domains` configuration
2. Missing `:user_module` configuration
3. Counter DSL error in resource

**Solution:**
```elixir
config :ash_dispatch,
  domains: [MyApp.Orders, MyApp.Tickets],
  user_module: MyApp.Accounts.User
```

### Counters Not Updating in Real-Time

**Problem:** Counter changes don't trigger broadcasts.

**Causes:**
1. `trigger_on` doesn't match action name
2. Counter DSL not properly configured
3. Broadcast function not configured

**Debug:**
```elixir
# Check counter definitions
AshDispatch.Dsl.Info.counters(MyApp.Orders.ProductOrder)

# Verify broadcast function
Application.get_env(:ash_dispatch, :counter_broadcast_fn)
```

---

## Next Steps

- [Counter Broadcasting](counter-broadcasting.md) - Define counters in your resources
- [Configuration](configuration.md) - Complete configuration reference
