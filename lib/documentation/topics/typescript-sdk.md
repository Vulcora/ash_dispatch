# TypeScript SDK

AshDispatch generates a complete TypeScript SDK for real-time counter management and notification handling. This guide explains how to use the generated SDK in your frontend application.

## Prerequisites

Before using the SDK, ensure you have:

1. `ash_typescript` configured with an output path
2. Run `mix ash_dispatch.gen` to generate the SDK files

```elixir
# config/config.exs
config :ash_typescript,
  output_file: "apps/frontend/src/lib/ash_rpc.ts"

# SDK will be generated to: apps/frontend/src/lib/ash-dispatch/
```

---

## Generated Files

The SDK is generated to `{ash_typescript_dir}/ash-dispatch/`:

```
lib/ash-dispatch/
├── types.ts              # Counter types, defaults, metadata
├── events.ts             # Event ID types and metadata
├── store.ts              # Zustand store for counter state
├── channel.ts            # Phoenix channel utilities
├── index.ts              # Re-exports all modules
└── hooks/
    ├── use-channel.ts    # Channel connection hook
    ├── use-counter.ts    # Single counter access hook
    └── use-notifications.ts  # Notification actions hook
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
│  │   :cart_items│      └──────────────┘      └──────────────┘      │
│  └──────────────┘                                   │               │
└─────────────────────────────────────────────────────│───────────────┘
                                                      │ WebSocket
┌─────────────────────────────────────────────────────│───────────────┐
│                         FRONTEND                    ▼               │
├─────────────────────────────────────────────────────────────────────┤
│  ┌──────────────┐      ┌──────────────┐      ┌──────────────┐      │
│  │ useUser      │      │ useCounter   │      │ React        │      │
│  │ Channel      │ ───► │ Store        │ ───► │ Components   │      │
│  │ (connects)   │      │ (Zustand)    │      │              │      │
│  └──────────────┘      └──────────────┘      └──────────────┘      │
│                              ▲                                      │
│                              │                                      │
│                        ┌─────┴──────┐                               │
│                        │ useCounters│ (camelCase accessors)         │
│                        └────────────┘                               │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Quick Start

### 1. Set Up the WebSocket Connection

Create a hook that establishes the WebSocket connection. This should be called once at app root:

```tsx
// hooks/use-user-channel.ts
import { useEffect, useRef } from 'react'
import { Socket, Channel } from 'phoenix'
import { useAuth } from '@/lib/auth/hooks'
import { useCounterStore } from '@/lib/stores/use-counter-store'
import { isValidCounter } from '@/lib/ash-dispatch'

export function useUserChannel() {
  const { data: user } = useAuth()
  const socketRef = useRef<Socket | null>(null)
  const channelRef = useRef<Channel | null>(null)
  const { setCounters, setCounter } = useCounterStore()

  useEffect(() => {
    if (!user?.id) return

    const connectSocket = async () => {
      // Get auth token from your backend
      const response = await fetch('/api/websocket-token', {
        credentials: 'include',
      })
      const { token } = await response.json()

      // Create Phoenix Socket
      const wsUrl = `${window.location.protocol === 'https:' ? 'wss:' : 'ws:'}//${window.location.host}/socket`
      const socket = new Socket(wsUrl, { params: { token } })
      socket.connect()

      // Join user channel
      const channel = socket.channel(`user:${user.id}`, {})

      // Set up event listeners BEFORE joining
      channel.on('initial_state', (payload) => {
        if (payload.counters) {
          setCounters(payload.counters)
        }
      })

      channel.on('counter_updated', (payload) => {
        const counterName = payload.counter as string
        if (isValidCounter(counterName)) {
          setCounter(counterName, payload.value)
        }
      })

      // Join the channel
      channel.join()

      socketRef.current = socket
      channelRef.current = channel
    }

    connectSocket()

    return () => {
      channelRef.current?.leave()
      socketRef.current?.disconnect()
    }
  }, [user?.id, setCounters, setCounter])

  return { channel: channelRef.current }
}
```

### 2. Create the Counter Store

Use the generated types to create a properly typed Zustand store:

```tsx
// lib/stores/use-counter-store.ts
import { create } from 'zustand'
import {
  DEFAULT_COUNTERS,
  type AllCounters,
  type CounterName
} from '@/lib/ash-dispatch'

interface CounterState {
  counters: AllCounters
  setCounters: (counters: Partial<AllCounters>) => void
  setCounter: (key: CounterName, value: number) => void
  resetCounters: () => void
}

export const useCounterStore = create<CounterState>()((set) => ({
  counters: DEFAULT_COUNTERS,

  setCounters: (newCounters) => {
    set((state) => ({
      counters: { ...state.counters, ...newCounters },
    }))
  },

  setCounter: (key, value) => {
    set((state) => ({
      counters: { ...state.counters, [key]: value },
    }))
  },

  resetCounters: () => {
    set({ counters: DEFAULT_COUNTERS })
  },
}))
```

### 3. Create the useCounters Hook

Provide camelCase accessors for ergonomic usage in components:

```tsx
// hooks/use-counters.ts
import { useCounterStore } from '@/lib/stores/use-counter-store'
import { getCounterAccessors } from '@/lib/ash-dispatch'

/**
 * Hook for accessing real-time counters with camelCase names.
 *
 * Counter accessors are auto-generated from Elixir DSL definitions.
 * Run `mix ash_dispatch.gen` to regenerate when counters change.
 *
 * @example
 * ```tsx
 * function Dashboard() {
 *   const { cartItems, openTickets, pendingOrders } = useCounters()
 *   return <Badge>{cartItems}</Badge>
 * }
 * ```
 */
export function useCounters() {
  const counters = useCounterStore((state) => state.counters)

  return {
    ...getCounterAccessors(counters),
    counters, // Raw counters object if needed (snake_case keys)
  }
}
```

---

## Using Counters in Components

### Basic Usage

```tsx
function CartBadge() {
  const { cartItems } = useCounters()

  if (cartItems === 0) return null

  return <Badge>{cartItems}</Badge>
}
```

### Navigation with Counters

```tsx
import { useCounters } from '@/hooks/use-counters'
import { type CounterName } from '@/lib/ash-dispatch'

interface NavItem {
  href: string
  label: string
  counter?: CounterName  // Type-safe counter names!
}

const navItems: NavItem[] = [
  { href: '/cart', label: 'Cart', counter: 'cart_items' },
  { href: '/tickets', label: 'Tickets', counter: 'open_tickets' },
  { href: '/orders', label: 'Orders', counter: 'pending_orders' },
]

function Navigation() {
  const { counters } = useCounters()

  return (
    <nav>
      {navItems.map((item) => (
        <NavLink key={item.href} href={item.href}>
          {item.label}
          {item.counter && counters[item.counter] > 0 && (
            <Badge>{counters[item.counter]}</Badge>
          )}
        </NavLink>
      ))}
    </nav>
  )
}
```

### Admin vs User Counters

Counters can have different audiences. Admin counters show global counts, user counters show per-user counts:

```tsx
function AdminDashboard() {
  const {
    // Admin counters (global counts)
    adminPendingOrders,
    adminOpenTickets,
    adminPendingResellerRequests,

    // User counters (if admin is also a user)
    cartItems,
  } = useCounters()

  return (
    <div>
      <StatCard label="Pending Orders" value={adminPendingOrders} />
      <StatCard label="Open Tickets" value={adminOpenTickets} />
      <StatCard label="Applications" value={adminPendingResellerRequests} />
    </div>
  )
}
```

---

## Handling Notifications

### Create a Notification Hook

```tsx
// hooks/use-notifications.ts
import { useCallback } from 'react'
import { useNotificationStore } from '@/lib/stores/use-notification-store'
import { useCounterStore } from '@/lib/stores/use-counter-store'
import { useAuth } from '@/lib/auth/hooks'
import { markNotificationAsRead, markAllNotificationsAsRead, buildCSRFHeaders } from '@/lib/ash_rpc'

/**
 * Hook for managing notifications with optimistic updates.
 *
 * Provides access to notification list, unread count, and methods
 * to mark notifications as read.
 *
 * @example
 * ```tsx
 * function NotificationBell() {
 *   const { notifications, unreadCount, markAsRead } = useNotifications()
 *
 *   return (
 *     <Popover>
 *       <PopoverTrigger>
 *         <Bell />
 *         {unreadCount > 0 && <Badge>{unreadCount}</Badge>}
 *       </PopoverTrigger>
 *       <PopoverContent>
 *         {notifications.map(n => (
 *           <NotificationItem
 *             key={n.id}
 *             notification={n}
 *             onRead={() => markAsRead(n.id)}
 *           />
 *         ))}
 *       </PopoverContent>
 *     </Popover>
 *   )
 * }
 * ```
 */
export function useNotifications() {
  const store = useNotificationStore()
  const unreadCount = useCounterStore((state) => state.counters.unread_notifications)
  const { data: user } = useAuth()

  const markAsRead = useCallback(async (notificationId: string) => {
    // Optimistic update
    store.markAsRead(notificationId)

    try {
      await markNotificationAsRead({
        primaryKey: notificationId,
        fields: ["id", "read"],
        headers: buildCSRFHeaders()
      })
    } catch (err) {
      console.error('Failed to mark notification as read:', err)
    }
  }, [store])

  const markAllAsRead = useCallback(async () => {
    if (!user?.id) return

    store.markAllAsRead()

    try {
      await markAllNotificationsAsRead({
        input: { userId: user.id },
        headers: buildCSRFHeaders()
      })
    } catch (err) {
      console.error('Failed to mark all notifications as read:', err)
    }
  }, [store, user?.id])

  return {
    notifications: store.notifications,
    unreadCount,
    markAsRead,
    markAllAsRead,
  }
}
```

### Create Notification Store

```tsx
// lib/stores/use-notification-store.ts
import { create } from 'zustand'

interface Notification {
  id: string
  title: string
  message: string
  read: boolean
  action_url?: string
  notification_type?: 'info' | 'success' | 'warning' | 'error'
  created_at: string
}

interface NotificationState {
  notifications: Notification[]
  syncNotifications: (notifications: Notification[]) => void
  addNotification: (notification: Notification) => void
  updateNotification: (id: string, updates: Partial<Notification>) => void
  markAsRead: (id: string) => void
  markAllAsRead: () => void
}

export const useNotificationStore = create<NotificationState>()((set) => ({
  notifications: [],

  syncNotifications: (notifications) => {
    set({ notifications })
  },

  addNotification: (notification) => {
    set((state) => ({
      notifications: [notification, ...state.notifications],
    }))
  },

  updateNotification: (id, updates) => {
    set((state) => ({
      notifications: state.notifications.map((n) =>
        n.id === id ? { ...n, ...updates } : n
      ),
    }))
  },

  markAsRead: (id) => {
    set((state) => ({
      notifications: state.notifications.map((n) =>
        n.id === id ? { ...n, read: true } : n
      ),
    }))
  },

  markAllAsRead: () => {
    set((state) => ({
      notifications: state.notifications.map((n) => ({ ...n, read: true })),
    }))
  },
}))
```

---

## WebSocket Events Reference

The backend sends these events over the user channel:

| Event | Payload | Description |
|-------|---------|-------------|
| `initial_state` | `{ counters, notifications }` | Sent on channel join |
| `counter_updated` | `{ counter, value, metadata? }` | Single counter changed |
| `counters_updated` | `{ counters }` | Multiple counters changed |
| `new_notification` | `Notification` | New in-app notification |
| `notification_updated` | `{ id, ...updates }` | Notification was updated |
| `all_notifications_read` | `{}` | All notifications marked read |

### Handling Counter Updates with Query Invalidation

The backend can include `invalidate_queries` in counter update metadata:

```tsx
channel.on('counter_updated', (payload) => {
  const counterName = payload.counter as string
  if (isValidCounter(counterName)) {
    setCounter(counterName, payload.value)
  }

  // Invalidate React Query caches based on backend metadata
  if (payload.metadata?.invalidate_queries) {
    payload.metadata.invalidate_queries.forEach((queryKey: string) => {
      queryClient.invalidateQueries({ queryKey: [queryKey] })
    })
  }
})
```

---

## Generated Types Reference

### Counter Types

```typescript
// Auto-generated in types.ts

// Grouped counter types
export type OrdersCounters = {
  pending_orders: number;
  processing_orders: number;
  admin_pending_orders: number;
  admin_processing_orders: number;
};

export type TicketsCounters = {
  open_tickets: number;
  processing_tickets: number;
  admin_open_tickets: number;
};

// Combined type
export type AllCounters = OrdersCounters & TicketsCounters & CatalogCounters;

// Default values
export const DEFAULT_COUNTERS: AllCounters = {
  pending_orders: 0,
  processing_orders: 0,
  // ...
};

// Counter name union type
export type CounterName = "pending_orders" | "processing_orders" | "open_tickets" | ...;

// Type guard
export function isValidCounter(name: string): name is CounterName;

// CamelCase accessors
export type CounterAccessors = {
  pendingOrders: number;
  processingOrders: number;
  openTickets: number;
  // ...
};

export function getCounterAccessors(counters: AllCounters): CounterAccessors;
```

### Event Types

```typescript
// Auto-generated in events.ts

export type EventId =
  | "orders.created"
  | "orders.completed"
  | "tickets.created"
  | "tickets.resolved";

export const EVENT_METADATA = {
  "orders.created": {
    domain: "orders",
    channels: [
      { transport: "email", audience: "user" },
      { transport: "email", audience: "admin", variant: "admin" },
      { transport: "in_app", audience: "user" },
    ],
  },
  // ...
} as const;

export function isValidEventId(id: string): id is EventId;

export type Transport = "email" | "in_app" | "sms" | "webhook" | "discord" | "slack";
export type Audience = "user" | "admin" | "system";
```

---

## Naming Convention

| Elixir (DSL) | TypeScript Store | TypeScript Accessor |
|--------------|------------------|---------------------|
| `:cart_items` | `counters.cart_items` | `cartItems` |
| `:open_tickets` | `counters.open_tickets` | `openTickets` |
| `:admin_pending_orders` | `counters.admin_pending_orders` | `adminPendingOrders` |

Use snake_case when accessing raw `counters` object, camelCase when using destructured accessors.

---

## Regenerating the SDK

When you add or modify counters in your Elixir DSL:

```bash
# Regenerate TypeScript SDK
mix ash_dispatch.gen

# Or with other ash codegen
mix ash.codegen
```

The generator will:
1. Introspect all counter definitions across resources
2. Update `types.ts` with new counter types
3. Update `events.ts` with new event metadata
4. Preserve your custom hooks and stores

---

## Next Steps

- [Phoenix Integration](phoenix-integration.md) - Backend channel setup
- [Counter Broadcasting](counter-broadcasting.md) - Define counters in DSL
- [Code Generation](code-generation.md) - Generator options and troubleshooting
