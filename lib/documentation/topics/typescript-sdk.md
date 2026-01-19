# TypeScript SDK

AshDispatch generates a complete TypeScript SDK for real-time counter management and notification handling. The SDK includes ready-to-use React components and hooks - no manual setup required.

## Prerequisites

Before using the SDK, ensure you have:

1. `ash_typescript` configured with an output path
2. Required peer dependencies installed

```elixir
# config/config.exs
config :ash_typescript,
  output_file: "apps/frontend/src/lib/ash_rpc.ts"

# SDK will be generated to: apps/frontend/src/lib/ash-dispatch/
```

```bash
# Install peer dependencies
npm install zustand phoenix
# or
pnpm add zustand phoenix
```

Run the generator:

```bash
mix ash_dispatch.gen
```

---

## Generated Files

```
lib/ash-dispatch/
├── types.ts                  # Counter types, defaults, metadata
├── events.ts                 # Event ID types and metadata
├── store.ts                  # Zustand store for counter state
├── channel.ts                # Phoenix channel utilities
├── index.ts                  # Re-exports all modules
├── hooks/
│   ├── use-channel.ts        # Channel connection hook
│   ├── use-counter.ts        # Single counter access hook
│   └── use-notifications.ts  # Complete notification management hook
├── notification-provider.tsx # React context provider
├── notification-bell.tsx     # Drop-in bell component with badge
└── README.md                 # Usage documentation
```

---

## Quick Start

### 1. Add NotificationProvider to Your Layout

Wrap your authenticated app with `NotificationProvider`. Pass your ash_typescript RPC functions directly:

```tsx
// app/(app)/layout.tsx or your authenticated layout
"use client"

import { NotificationProvider } from '@/lib/generated/ash-dispatch/notification-provider'
import {
  listNotifications,
  markNotificationAsRead,
  markAllNotificationsAsRead,
  buildCSRFHeaders,
} from '@/lib/generated/ash_rpc'
import { useAuth } from '@/lib/auth-context'

export default function AppLayout({ children }: { children: React.ReactNode }) {
  const { user } = useAuth()

  if (!user) return <LoadingSpinner />

  return (
    <NotificationProvider
      userId={user.id}
      listNotifications={listNotifications}
      markNotificationAsRead={markNotificationAsRead}
      markAllNotificationsAsRead={markAllNotificationsAsRead}
      buildCSRFHeaders={buildCSRFHeaders}
    >
      <Sidebar />
      <main>{children}</main>
    </NotificationProvider>
  )
}
```

### 2. Use Notifications in Components

Access notifications anywhere using `useNotificationContext`:

```tsx
// components/notification-center.tsx
import { useNotificationContext } from '@/lib/generated/ash-dispatch'

export function NotificationCenter() {
  const {
    notifications,
    unreadCount,
    isLoading,
    markAsRead,
    markAllAsRead,
  } = useNotificationContext()

  return (
    <div>
      <header>
        <span>Notifications ({unreadCount} unread)</span>
        <button onClick={markAllAsRead}>Mark all as read</button>
      </header>

      {isLoading ? (
        <div>Loading...</div>
      ) : (
        <ul>
          {notifications.map((n) => (
            <li
              key={n.id}
              onClick={() => markAsRead(n.id)}
              className={n.read ? 'opacity-50' : ''}
            >
              <strong>{n.title}</strong>
              <p>{n.message}</p>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
```

### 3. Use the NotificationBell Component

For a quick drop-in bell icon with badge:

```tsx
import { NotificationBell } from '@/lib/generated/ash-dispatch/notification-bell'

function Header() {
  const [showPanel, setShowPanel] = useState(false)

  return (
    <header>
      <NotificationBell onClick={() => setShowPanel(true)} />
      {showPanel && <NotificationPanel onClose={() => setShowPanel(false)} />}
    </header>
  )
}
```

Customize with props:

```tsx
<NotificationBell
  className="text-gray-600 hover:text-gray-900"
  maxCount={99}
  showBadge={true}
  icon={<IconBell className="size-5" />}  // Custom icon
  onClick={() => router.push('/notifications')}
/>
```

---

## Using Counters Directly

For simple counter access without the full notification system:

### Single Counter

```tsx
import { useCounter } from '@/lib/generated/ash-dispatch'

function CartBadge() {
  const cartItems = useCounter('cart_items')

  if (cartItems === 0) return null
  return <Badge>{cartItems}</Badge>
}
```

### All Counters

```tsx
import { useCounterStore, type CounterState } from '@/lib/generated/ash-dispatch/store'

function Dashboard() {
  const counters = useCounterStore((state: CounterState) => state.counters)

  return (
    <div>
      <StatCard label="Cart" value={counters.cart_items} />
      <StatCard label="Tickets" value={counters.open_tickets} />
    </div>
  )
}
```

### Setting Counters Programmatically

The store provides `setCounter` for single updates and `setCounters` for bulk updates:

```tsx
import { useCounterStore } from '@/lib/generated/ash-dispatch/store'

// Single counter update
useCounterStore.getState().setCounter('cart_items', 5)

// Bulk update (used internally by initial_state handler)
useCounterStore.getState().setCounters({
  cart_items: 3,
  unread_notifications: 10,
  pending_tasks: 2
})
```

The `setCounters` function merges provided counters with existing state, only updating keys that are present in the payload.

### CamelCase Accessors

Use the generated accessor helper for ergonomic naming:

```tsx
import { useCounterStore } from '@/lib/generated/ash-dispatch/store'
import { getCounterAccessors } from '@/lib/generated/ash-dispatch/types'

function useCounters() {
  const counters = useCounterStore((state) => state.counters)
  return getCounterAccessors(counters)
}

// Usage
function Dashboard() {
  const { cartItems, openTickets, unreadNotifications } = useCounters()
  // ...
}
```

---

## Navigation Badges

Add counter badges to your navigation:

```tsx
import { useCounterStore, type CounterState } from '@/lib/generated/ash-dispatch/store'
import type { CounterName } from '@/lib/generated/ash-dispatch/types'

interface NavItem {
  href: string
  label: string
  icon: React.ComponentType
  counterKey?: CounterName  // Type-safe!
}

const navItems: NavItem[] = [
  { href: '/inbox', label: 'Inbox', icon: IconInbox, counterKey: 'unread_messages' },
  { href: '/notifications', label: 'Notifications', icon: IconBell, counterKey: 'unread_notifications' },
  { href: '/tasks', label: 'Tasks', icon: IconTasks, counterKey: 'pending_tasks' },
]

function Navigation() {
  const counters = useCounterStore((state: CounterState) => state.counters)

  return (
    <nav>
      {navItems.map((item) => (
        <NavLink key={item.href} href={item.href}>
          <item.icon />
          <span>{item.label}</span>
          {item.counterKey && counters[item.counterKey] > 0 && (
            <Badge>{counters[item.counterKey]}</Badge>
          )}
        </NavLink>
      ))}
    </nav>
  )
}
```

---

## Real-time Updates

The SDK automatically connects to Phoenix channels when `NotificationProvider` mounts. It handles:

- Initial counter state via `initial_state` event on channel join
- Initial notification fetch via RPC
- WebSocket connection to `user:{userId}` channel (configurable topic)
- Real-time counter updates via `counter_update` events
- New notification pushes via `new_notification` events

### React StrictMode Safety

The SDK hooks use a `mountedRef` pattern to safely handle React's StrictMode double-mounting behavior. This prevents:

- State updates after component unmount
- Memory leaks from orphaned callbacks
- Race conditions during rapid mount/unmount cycles

The implementation ensures cleanup functions properly disconnect channels and prevent stale updates:

```tsx
// Internal pattern used by SDK hooks
const mountedRef = useRef(true)

useEffect(() => {
  mountedRef.current = true

  // Channel setup with guard checks
  channel.on('counter_update', (payload) => {
    if (!mountedRef.current) return  // Skip if unmounted
    setCounter(payload.name, payload.value)
  })

  return () => {
    mountedRef.current = false
    channel.leave()
  }
}, [])
```

This pattern is automatically applied - no additional configuration needed.

### Backend Requirements

Ensure your Phoenix backend has:

1. **Socket endpoint** at `/socket`
2. **User channel** - Default topic is `user:{userId}`, configurable via:
   ```elixir
   # config/config.exs
   config :ash_dispatch,
     channel_topic: "inbox"  # Changes to "inbox:{userId}"
   ```
3. **Socket token endpoint** at `/api/inbox/socket-token` returning:
   ```json
   { "success": true, "data": { "token": "..." } }
   ```
4. **Initial state push** - Channel should push `initial_state` on join:
   ```elixir
   # In your channel join handler
   def join("user:" <> user_id, _params, socket) do
     initial_state = AshDispatch.Helpers.ChannelState.build(user_id)
     send(self(), {:after_join, initial_state})
     {:ok, socket}
   end

   def handle_info({:after_join, state}, socket) do
     push(socket, "initial_state", state)
     {:noreply, socket}
   end
   ```

### Channel Events

| Event | Payload | Description |
|-------|---------|-------------|
| `initial_state` | `{ counters: AllCounters }` | Initial state on channel join |
| `counter_update` | `{ counter_name: number }` | Single counter changed |
| `new_notification` | `Notification` | New notification received |

The `initial_state` event is sent immediately when joining the channel, providing all current counter values. This eliminates the need for separate RPC calls to fetch initial counter state.

---

## Query Invalidation

Events can specify query keys to invalidate when notifications are received. This is useful for
triggering cache refreshes in TanStack Query or custom state management.

### Backend Configuration

In your Elixir DSL, add `invalidates` to events:

```elixir
dispatch do
  event :order_created,
    trigger_on: :create,
    channels: [[transport: :in_app, audience: :user]],
    invalidates: ["orders", "order_stats"]  # Frontend query keys
end
```

### Using with TanStack Query

Pass `onInvalidate` to the `useNotifications` hook:

```tsx
import { useQueryClient } from '@tanstack/react-query'
import { useNotifications } from '@/lib/generated/ash-dispatch'

function NotificationsWithInvalidation() {
  const queryClient = useQueryClient()

  const { notifications } = useNotifications({
    userId: user.id,
    listNotifications,
    markNotificationAsRead,
    markAllNotificationsAsRead,
    buildCSRFHeaders,
    onInvalidate: (queryKeys) => {
      // Invalidate matching TanStack Query caches
      queryKeys.forEach((key) => {
        queryClient.invalidates({ queryKey: [key] })
      })
    },
  })

  return <NotificationList notifications={notifications} />
}
```

### Using with Custom State Management

For apps without TanStack Query, use window events or a custom mechanism:

```tsx
// In your notification setup
onInvalidate: (queryKeys) => {
  // Broadcast a custom event
  window.dispatchEvent(
    new CustomEvent('invalidate-queries', { detail: { queryKeys } })
  )
}

// In any component that needs to respond
useEffect(() => {
  const handler = (e: CustomEvent<{ queryKeys: string[] }>) => {
    if (e.detail.queryKeys.includes('orders')) {
      refetchOrders()
    }
  }
  window.addEventListener('invalidate-queries', handler)
  return () => window.removeEventListener('invalidate-queries', handler)
}, [refetchOrders])
```

---

## Low-Level Channel Hook

For custom channel handling, use `useChannel`:

```tsx
import { useChannel } from '@/lib/generated/ash-dispatch'

function MyComponent() {
  const [channel, setChannel] = useState<Channel | null>(null)

  useChannel({
    channel,
    onNotification: (notification) => {
      // Custom notification handling
      toast.info(notification.title)
    },
  })

  // ...
}
```

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         ELIXIR BACKEND                              │
├─────────────────────────────────────────────────────────────────────┤
│  Resource DSL          AshDispatch           Phoenix Channel        │
│  ┌──────────────┐      ┌──────────────┐      ┌──────────────┐      │
│  │ counters do  │      │ Counter      │      │ user:123     │      │
│  │   counter    │ ───► │ Broadcaster  │ ───► │ channel      │      │
│  │   :unread_   │      └──────────────┘      └──────────────┘      │
│  │   notif...   │                                   │               │
│  └──────────────┘                                   │               │
└─────────────────────────────────────────────────────│───────────────┘
                                                      │ WebSocket
┌─────────────────────────────────────────────────────│───────────────┐
│                         FRONTEND                    ▼               │
├─────────────────────────────────────────────────────────────────────┤
│  ┌──────────────────┐    ┌──────────────┐    ┌──────────────┐      │
│  │ Notification     │    │ Counter      │    │ React        │      │
│  │ Provider         │───►│ Store        │───►│ Components   │      │
│  │ (connects,       │    │ (Zustand)    │    │              │      │
│  │  fetches RPC)    │    └──────────────┘    └──────────────┘      │
│  └──────────────────┘           ▲                                   │
│           │                     │                                   │
│           ▼                ┌────┴─────┐                             │
│  ┌──────────────────┐      │useCounter│                             │
│  │useNotification   │      │useCounters│                            │
│  │Context           │      └──────────┘                             │
│  └──────────────────┘                                               │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Generated Types Reference

### Notification Type

```typescript
interface Notification {
  id: string
  title: string
  message: string
  type: 'info' | 'success' | 'warning' | 'error'
  actionUrl: string | null
  actionLabel: string | null
  read: boolean
  readAt: string | null
  occurredAt: string
  insertedAt: string
  /** Query keys to invalidate (from event's invalidates option) */
  invalidates?: string[]
}
```

### Counter Types

```typescript
// Generated based on your DSL definitions
export type AllCounters = {
  unread_notifications: number;
  cart_items: number;
  // ... other counters from your resources
};

export type CounterName = keyof AllCounters;

export const DEFAULT_COUNTERS: AllCounters = {
  unread_notifications: 0,
  cart_items: 0,
  // ...
};

// Type guard
export function isValidCounter(name: string): name is CounterName;

// CamelCase accessors
export function getCounterAccessors(counters: AllCounters): CounterAccessors;
```

### Counter Store

```typescript
interface CounterState {
  counters: AllCounters
  setCounter: (name: CounterName, value: number) => void
  setCounters: (counters: Partial<AllCounters>) => void
  incrementCounter: (name: CounterName, by?: number) => void
  decrementCounter: (name: CounterName, by?: number) => void
  resetCounters: () => void
}
```

The `setCounters` function is used by the `initial_state` event handler to set all counters at once when joining the channel.

### Hook Return Types

```typescript
interface UseNotificationsReturn {
  notifications: Notification[]
  unreadCount: number
  isLoading: boolean
  error: string | null
  isConnected: boolean
  markAsRead: (notificationId: string) => Promise<void>
  markAllAsRead: () => Promise<void>
  refresh: () => Promise<void>
}
```

---

## Regenerating the SDK

When you add or modify counters/events in your Elixir DSL:

```bash
# Regenerate TypeScript SDK
mix ash_dispatch.gen

# Or with other ash codegen
mix ash.codegen
```

The generator will:
1. Introspect all counter and event definitions
2. Update `types.ts` with new counter types
3. Update `events.ts` with new event metadata
4. Regenerate SDK files only if content changed
5. Check for missing peer dependencies and warn

---

## Naming Convention

| Elixir (DSL) | TypeScript Store | TypeScript Accessor |
|--------------|------------------|---------------------|
| `:cart_items` | `counters.cart_items` | `cartItems` |
| `:unread_notifications` | `counters.unread_notifications` | `unreadNotifications` |
| `:admin_pending_orders` | `counters.admin_pending_orders` | `adminPendingOrders` |

Use snake_case when accessing raw `counters` object, camelCase when using accessor helpers.

---

## Next Steps

- [Phoenix Integration](phoenix-integration.md) - Backend channel setup
- [Counter Broadcasting](counter-broadcasting.md) - Define counters in DSL
- [Code Generation](code-generation.md) - Generator options and troubleshooting
