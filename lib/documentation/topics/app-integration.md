# Integrating AshDispatch into Your Application

After completing the [Getting Started tutorial](../tutorials/getting-started.md), you have events triggering from your resources. This guide covers the essential integration steps to make AshDispatch production-ready in your application.

## Overview

AshDispatch provides base resources (`Notification.Base`, `DeliveryReceipt.Base`) that you extend in your app. This pattern allows you to:

- Add your own User relationship
- Store data in your database (not ETS)
- Add custom policies and validations
- Expose actions via RPC to your frontend

**Time estimate:** 15-30 minutes for initial setup

## Prerequisites

- Completed [Getting Started tutorial](../tutorials/getting-started.md)
- Existing User resource in your app
- PostgreSQL database configured

---

## Step 1: Create Your Notification Resource

AshDispatch's `Notification.Base` provides all attributes, actions, and counter broadcasting. You extend it to add your User relationship.

### 1.1 Create the resource file

```elixir
# lib/my_app/notifications/notification.ex
defmodule MyApp.Notifications.Notification do
  @moduledoc """
  In-app notifications for users.
  Extends AshDispatch.Resources.Notification.Base with User relationship.
  """

  use AshDispatch.Resources.Notification.Base,
    repo: MyApp.Repo,
    domain: MyApp.Notifications,
    extensions: [AshTypescript.Resource]  # Optional - add if using TypeScript

  # TypeScript type configuration (requires AshTypescript.Resource extension above)
  typescript do
    type_name("Notification")
  end

  # Add your User relationship
  relationships do
    belongs_to :user, MyApp.Accounts.User do
      source_attribute :user_id
      destination_attribute :id
      allow_nil? false
      public? true
      define_attribute? false  # Base already defines user_id
    end
  end

  # Optional: Add policies
  # policies do
  #   policy action_type(:read) do
  #     authorize_if expr(user_id == ^actor(:id))
  #   end
  # end
end
```

### 1.2 Create the domain

```elixir
# lib/my_app/notifications.ex
defmodule MyApp.Notifications do
  use Ash.Domain,
    otp_app: :my_app,
    extensions: [AshTypescript.Rpc]  # If using RPC

  # RPC actions for frontend (optional)
  typescript_rpc do
    resource MyApp.Notifications.Notification do
      rpc_action :list_notifications, :list_for_user
      rpc_action :mark_notification_as_read, :mark_as_read
      rpc_action :mark_all_notifications_as_read, :mark_all_as_read
    end
  end

  resources do
    resource MyApp.Notifications.Notification do
      # Domain functions
      define :get_notification, action: :get, args: [:id], get?: true
      define :list_notifications, action: :list_for_user, args: [:user_id]
      define :mark_notification_as_read, action: :mark_as_read
      define :mark_all_notifications_as_read, action: :mark_all_as_read, args: [:user_id]
    end
  end
end
```

### 1.3 Generate the migration

```bash
mix ash.codegen add_notifications_table
```

This creates a migration for the `notifications` table with all required columns.

### 1.4 Configure AshDispatch to use your resource

```elixir
# config/config.exs
config :ash_dispatch,
  notification_resource: MyApp.Notifications.Notification
```

---

## Step 2: Create Your DeliveryReceipt Resource (Optional)

If you want delivery tracking stored in your database (recommended for production):

### 2.1 Create the resource file

```elixir
# lib/my_app/deliveries/delivery_receipt.ex
defmodule MyApp.Deliveries.DeliveryReceipt do
  @moduledoc """
  Tracks all notification deliveries (email, in-app, webhooks).
  """

  use AshDispatch.Resources.DeliveryReceipt.Base,
    repo: MyApp.Repo,
    domain: MyApp.Deliveries,
    notification_resource: MyApp.Notifications.Notification,  # Required!
    extensions: [AshTypescript.Resource]  # Optional - add if using TypeScript

  # TypeScript type configuration (requires AshTypescript.Resource extension above)
  typescript do
    type_name("DeliveryReceipt")
  end

  # Add your User relationship
  relationships do
    belongs_to :user, MyApp.Accounts.User do
      source_attribute :user_id
      destination_attribute :id
      allow_nil? true
      public? true
    end
  end
end
```

### 2.2 Create the domain

```elixir
# lib/my_app/deliveries.ex
defmodule MyApp.Deliveries do
  use Ash.Domain, otp_app: :my_app

  resources do
    resource MyApp.Deliveries.DeliveryReceipt do
      define :list_receipts, action: :read
      define :get_receipt, action: :read, get_by: [:id]
    end
  end
end
```

### 2.3 Generate the migration

```bash
mix ash.codegen add_delivery_receipts_table
```

### 2.4 Configure AshDispatch

```elixir
# config/config.exs
config :ash_dispatch,
  notification_resource: MyApp.Notifications.Notification,
  delivery_receipt_resource: MyApp.Deliveries.DeliveryReceipt
```

---

## Step 3: Register Domains with Ash

Add your new domains to your application's Ash configuration:

```elixir
# config/config.exs
config :my_app,
  ash_domains: [
    MyApp.Accounts,
    MyApp.Orders,
    MyApp.Notifications,  # Add this
    MyApp.Deliveries      # Add this if using custom DeliveryReceipt
  ]
```

---

## Step 4: Setup and Templates

Before generating events, set up the directory structure and layouts:

### 4.1 Initial Setup

```bash
# Creates layouts and directory structure
mix ash_dispatch.setup
```

This creates:
```
priv/ash_dispatch/
├── layouts/
│   ├── email.html.heex    # Customize with your brand
│   └── email.text.eex
└── templates/             # Event templates go here
```

### 4.2 Customize Your Layout

Edit `priv/ash_dispatch/layouts/email.html.heex` with your branding:
- Logo and header styling
- Brand colors
- Footer with contact info

All event templates will automatically use this layout - they only need event-specific content.

### 4.3 Define Events in Resource DSL

Events are defined in your resource using the `dispatch do` block:

```elixir
# lib/my_app/orders/product_order.ex
defmodule MyApp.Orders.ProductOrder do
  use Ash.Resource,
    extensions: [AshDispatch.Resource]

  dispatch do
    event :created do
      module MyApp.Orders.Events.Created.Event
      trigger_on [:create]
      data_key :order

      channels do
        channel :in_app, :user,
          title: "Order skapad",
          message: "Din order har registrerats"
        channel :email, :user,
          subject: "Din order har skapats"
      end
    end
  end
end
```

Then generate missing templates and event modules:

```bash
mix ash_dispatch.gen
# Or: mix ash.codegen
```

See [Generator](generator.md) for full documentation.

---

## Step 5: Frontend Integration

AshDispatch provides a complete TypeScript SDK for real-time updates.

### 5.1 Generate the SDK

```bash
# Generate everything: SDK, counter types, hooks
mix ash_dispatch.gen

# Also generate RPC types
mix ash_typescript.codegen
```

This creates:
- `lib/ash-dispatch/` - Complete SDK with hooks and stores
- `lib/counters.ts` - Type-safe counter definitions
- `ash_rpc.ts` - RPC action types

### 5.2 Use the Generated Hooks

```typescript
import { useCounter, useChannel, useCounterStore } from '@/lib/ash-dispatch'

// Single counter value
function CartBadge() {
  const cartItems = useCounter('cart_items')
  return <Badge count={cartItems} />
}

// All counters
function Dashboard() {
  const counters = useCounterStore(state => state.counters)
  return (
    <div>
      <span>Orders: {counters.pending_orders}</span>
      <span>Notifications: {counters.unread_notifications}</span>
    </div>
  )
}

// Channel connection
function AppProvider({ children }) {
  const channel = useUserChannel(userId)

  useChannel({
    channel,
    onNotification: (notification) => {
      toast.success(notification.title)
    }
  })

  return <>{children}</>
}
```

See [Generator](generator.md) for complete SDK documentation.

### 5.3 RPC Actions

**Important:** AshTypescript generates specific signatures. Check the generated code for exact parameter names.

```typescript
// ❌ Common mistake - wrong parameter names
await markNotificationAsRead({ id: notificationId })

// ❌ Common mistake - empty fields array
await markNotificationAsRead({
  primaryKey: notificationId,
  fields: [],  // ERROR: "Fields array cannot be empty"
  headers: buildCSRFHeaders()
})

// ✅ Correct - include at least one field
await markNotificationAsRead({
  primaryKey: notificationId,  // Update actions use primaryKey
  fields: ["id", "read"],      // Must include at least one field!
  headers: buildCSRFHeaders()
})

// ✅ Generic actions use input wrapper
await markAllNotificationsAsRead({
  input: { userId: user.id },   // Arguments wrapped in input
  headers: buildCSRFHeaders()
})
```

### 5.4 Example React hook

```typescript
import {
  markNotificationAsRead,
  markAllNotificationsAsRead,
  buildCSRFHeaders
} from '@/lib/ash_rpc'

export function useNotifications() {
  const markAsRead = async (notificationId: string) => {
    await markNotificationAsRead({
      primaryKey: notificationId,
      fields: ["id", "read"],  // Must include at least one field
      headers: buildCSRFHeaders()
    })
  }

  const markAllAsRead = async (userId: string) => {
    await markAllNotificationsAsRead({
      input: { userId },
      headers: buildCSRFHeaders()
    })
  }

  return { markAsRead, markAllAsRead }
}
```

---

## Step 6: Run Migrations

```bash
mix ash.migrate
```

---

## Complete Configuration Example

Here's a complete `config.exs` with all AshDispatch settings:

```elixir
# config/config.exs
config :ash_dispatch,
  # Required for layout discovery
  otp_app: :my_app,

  # Your custom resources
  notification_resource: MyApp.Notifications.Notification,
  delivery_receipt_resource: MyApp.Deliveries.DeliveryReceipt,

  # Counter broadcasting (for real-time updates)
  counter_broadcast_fn: {MyAppWeb.UserChannel, :broadcast_counter},
  domains: [MyApp.Orders, MyApp.Notifications, MyApp.Accounts],

  # User resolution
  user_resource: MyApp.Accounts.User,
  user_domain: MyApp.Accounts,

  # Email configuration
  email_backend: AshDispatch.EmailBackend.Swoosh,
  swoosh_mailer: MyApp.Mailer,
  default_from_email: {"My App", "noreply@myapp.com"},

  # Base URL for links
  base_url: "https://app.myapp.com",

  # Custom template formats (optional)
  # Add new formats for future transports like SMS, Discord, Slack
  format_extensions: %{
    # Defaults (already included):
    # html: "html.heex",
    # text: "text.eex",

    # Custom formats:
    markdown: "md.eex"     # For Discord/Slack messages
    # json: "json.eex"     # For webhook payloads
  }
```

---

## Verification Checklist

After completing setup, verify everything works:

### ☐ Database tables exist
```bash
mix ash.migrate
psql -d my_app_dev -c "\dt notifications"
psql -d my_app_dev -c "\dt delivery_receipts"
```

### ☐ Resources compile
```bash
mix compile --warnings-as-errors
```

### ☐ TypeScript types generate
```bash
mix ash_typescript.codegen
# Check that notification functions exist in generated file
```

### ☐ Test an event
```elixir
# In IEx
user = MyApp.Accounts.get_user!(user_id)
ticket = MyApp.Tickets.create_ticket!(%{title: "Test", user_id: user.id})

# Check notification was created
MyApp.Notifications.list_notifications(user.id)
```

### ☐ Test RPC from frontend
```typescript
// Should see database query in server logs
await markNotificationAsRead({
  primaryKey: notificationId,
  fields: [],
  headers: buildCSRFHeaders()
})
```

---

## Common Issues

### "No function clause matching"

**Cause:** Wrong parameter names in RPC call.

**Solution:** Check generated TypeScript for exact signature:
- Update actions: `{ primaryKey, fields }`
- Generic actions: `{ input: { ... } }`
- Read actions: `{ args: { ... } }` or direct parameters

### "Fields array cannot be empty"

**Cause:** RPC call has `fields: []` for an update/create action.

**Solution:** Include at least one field:
```typescript
await markNotificationAsRead({
  primaryKey: notificationId,
  fields: ["id", "read"],  // Not empty!
  headers: buildCSRFHeaders()
})
```

### "Notification not created"

**Cause:** `notification_resource` not configured.

**Solution:**
```elixir
config :ash_dispatch,
  notification_resource: MyApp.Notifications.Notification
```

### "relation does not exist"

**Cause:** Migration not run.

**Solution:**
```bash
mix ash.codegen add_notifications_table
mix ash.migrate
```

### Counter updates not broadcasting

**Cause:** `counter_broadcast_fn` not configured.

**Solution:** See [Phoenix Integration](phoenix-integration.md) for channel setup.

---

## Why Base Modules?

You might wonder why AshDispatch uses this "inheritance" pattern instead of just providing resources directly.

**The challenge:** AshDispatch can't know your app's User module at compile time.

**Alternatives considered:**

1. **Configure user_id as string** - Loses type safety and relationships
2. **Use polymorphic associations** - Complex and not idiomatic Ash
3. **Require manual resource creation** - Too much boilerplate

**The Base pattern** gives you:
- ✅ All standard attributes, actions, and counters pre-defined
- ✅ Full type safety with your User relationship
- ✅ Ability to add custom policies, calculations, validations
- ✅ Database storage in your schema
- ✅ No manual attribute copying

It's a few lines of setup for significant flexibility.

---

## Next Steps

- [Phoenix Integration](phoenix-integration.md) - Set up real-time channels
- [Counter Broadcasting](counter-broadcasting.md) - Define counters for live UI
- [User Preferences](user-preferences.md) - Let users control notifications
- [Configuration Reference](configuration.md) - All available options
