# What is AshDispatch?

## The Problem: Notification Sprawl

In most applications, notifications start simple but quickly become complex:

```elixir
# Started simple...
def create_order(params) do
  with {:ok, order} <- Orders.create(params) do
    Email.send_order_confirmation(order)
    {:ok, order}
  end
end

# Then grew organically...
def create_order(params) do
  with {:ok, order} <- Orders.create(params) do
    # Email to customer
    Email.send_order_confirmation(order.user)

    # Email to admin
    Email.send_admin_notification(order)

    # In-app notification
    Notifications.create_for_user(order.user, "Order created")

    # Discord webhook for team
    Discord.post_webhook("New order: #{order.number}")

    # Update dashboard counters
    PubSub.broadcast("update_order_count")

    {:ok, order}
  end
end
```

**Problems with this approach:**
- ❌ Notification logic scattered across codebase
- ❌ Hard to test (sends real emails in tests!)
- ❌ No user preferences (can't opt out)
- ❌ No delivery tracking (did it send?)
- ❌ No retry logic (fails silently)
- ❌ Not reusable (copy-paste for each resource)

## The Solution: Event-Driven Dispatch

AshDispatch moves notification logic into declarative resource definitions:

```elixir
defmodule Orders.ProductOrder do
  use Ash.Resource,
    extensions: [AshDispatch.Resource]

  actions do
    create :create_from_cart do
      accept [:user_id, :items]
      # Just create the order - AshDispatch handles notifications!
    end
  end

  dispatch do
    event :created,
      trigger_on: :create_from_cart,
      channels: [
        [transport: :email, audience: :user],
        [transport: :email, audience: :admin],
        [transport: :in_app, audience: :user],
        [transport: :discord, audience: :team, webhook_url: "..."]
      ],
      content: [
        subject: "Order #{{order_number}} created",
        notification_title: "Order Created",
        notification_message: "Your order is being processed"
      ]
  end
end
```

**Benefits:**
- ✅ All notification logic in one place
- ✅ Declarative and testable
- ✅ Automatic user preference checking
- ✅ Full delivery tracking with receipts
- ✅ Automatic retries on failure
- ✅ Reusable pattern across all resources

## Core Concepts

### 1. Events

Events represent things that happen in your system:
- Order created
- Ticket resolved
- User registered
- Payment failed

Events are defined in resources and automatically triggered by actions.

### 2. Transports

Transports are delivery mechanisms:
- `:email` - Send emails (via Swoosh)
- `:in_app` - Create in-app notifications
- `:discord` - Post to Discord webhooks
- `:slack` - Post to Slack webhooks
- `:sms` - Send SMS messages
- `:webhook` - Custom HTTP webhooks

### 3. Channels

Channels combine a transport with an audience and timing:

```elixir
[transport: :email, audience: :user, delay: 300]
```

This means: "Send an email to the user, 5 minutes from now"

### 4. Delivery Receipts

Every dispatched event creates a `DeliveryReceipt` Ash resource record:

```elixir
%AshDispatch.Resources.DeliveryReceipt{
  id: "a1b2c3d4...",
  event_id: "product_order.created",
  transport: :email,
  audience: :user,
  recipient: "user@example.com",
  status: :sent,
  sent_at: ~U[2025-01-16 10:30:00Z],
  # Full content stored for audit trail and retries
  subject: "Order #1234 created",
  body_html: "<h1>Order Created</h1>...",
  body_text: "Order #1234 created...",
  content: %{subject: "Order #1234 created", ...},
  # Retry tracking
  retry_count: 0,
  # Provider tracking
  provider_id: "msg_abc123",
  provider_response: %{...}
}
```

**Receipt Features:**
- ✅ Full Ash resource with state machine
- ✅ ETS data layer (override with Postgres in your app)
- ✅ State transitions: pending → scheduled → sending → sent/failed
- ✅ Automatic retry counting
- ✅ Provider response tracking
- ✅ Query receipts: `DeliveryReceipt |> Ash.Query.filter(status == :failed)`

**Receipts enable:**
- Audit trails ("When did we send this?")
- Delivery tracking ("Did it fail?")
- Retry logic ("Try again in 15 minutes")
- Analytics ("How many emails sent this month?")
- Debugging ("What content was sent?")

### 5. User Preferences

**Status:** 🚧 Coming Soon

Users will be able to opt out of configurable notifications:

```elixir
%UserEmailPreferences{
  user_id: user.id,
  order_updates: false,  # User opted out
  ticket_updates: true
}
```

AshDispatch will automatically check preferences before delivering. For now, all notifications are sent.

## How It Works

```mermaid
sequenceDiagram
    participant Action
    participant Transformer
    participant DispatchEvent
    participant Receipt
    participant Transport

    Note over Action: Resource action executes
    Transformer->>Action: Injects DispatchEvent change
    Action->>DispatchEvent: Calls after action success
    DispatchEvent->>Receipt: Creates DeliveryReceipt
    Receipt->>Transport: Dispatches to transport
    alt In-App
        Transport->>Notification: Creates notification
        Notification-->>Receipt: Updates status: sent
    else Email
        Transport->>Oban: Enqueues job
        Oban-->>Receipt: Updates status: scheduled
        Oban->>Email: Sends email
        Email-->>Receipt: Updates status: sent
    end
```

### Step-by-Step

1. **Compile Time**: Transformer injects `DispatchEvent` change into action
2. **Runtime**: Action executes successfully
3. **After Success**: `DispatchEvent` change runs
4. **Create Receipt**: `DeliveryReceipt` Ash resource created with full content (status: `:pending`)
5. **Dispatch**: For each channel:
   - **In-App**: ✅ Create `Notification`, update receipt to `:sent` immediately (via Ash changeset)
   - **Email**: 🚧 Enqueue Oban job (mocked), update receipt to `:scheduled` (via Ash changeset)
   - **Webhook**: 🚧 Enqueue Oban job (mocked), update receipt to `:scheduled` (via Ash changeset)
6. **Async Delivery**: 🚧 Oban jobs send emails/webhooks, update receipt status
7. **Retry on Failure**: 🚧 Failed receipts automatically retry via cron job

**Legend:**
- ✅ Fully implemented with real resources
- 🚧 Working with mocks (Oban jobs log instead of enqueueing)

## Progressive Complexity

### Level 1: Simple Inline Events

Perfect for straightforward notifications:

```elixir
dispatch do
  event :created,
    trigger_on: :create,
    channels: [[transport: :email, audience: :user]],
    content: [subject: "Welcome!"]
end
```

### Level 2: Multiple Channels & Timing

Add complexity as needed:

```elixir
dispatch do
  event :created,
    trigger_on: :create,
    channels: [
      [transport: :in_app, audience: :user],
      [transport: :email, audience: :user, delay: 300],
      [transport: :email, audience: :admin]
    ],
    content: [
      subject: "Order #{{order_number}} created",
      notification_title: "Order Created"
    ],
    metadata: [
      notification_type: :success,
      user_configurable: true
    ]
end
```

### Level 3: Callback Modules

When you need custom logic:

```elixir
dispatch do
  event :created,
    trigger_on: :create,
    module: MyApp.Events.Orders.Created
end
```

```elixir
defmodule MyApp.Events.Orders.Created do
  @behaviour AshDispatch.Event

  @impl true
  def channels(_context) do
    # Dynamic channel logic
    if weekend?() do
      [[transport: :in_app, audience: :user]]
    else
      [[transport: :email, audience: :user]]
    end
  end

  @impl true
  def recipients(context, channel) do
    # Custom recipient logic
    case channel.audience do
      :user -> [context.data.order.user]
      :admin -> fetch_admins_on_duty()
    end
  end

  # ... more callbacks
end
```

## Comparison with Alternatives

### Manual Event Handling

```elixir
# Before: Scattered logic
def create_order(params) do
  {:ok, order} = Orders.create(params)
  Email.send(order.user, "Order created")
  Notifications.create(order.user, "Order created")
  Discord.post("New order")
  {:ok, order}
end
```

```elixir
# After: Declarative
dispatch do
  event :created, trigger_on: :create, ...
end
```

### Phoenix PubSub

PubSub is great for real-time updates, but doesn't handle:
- Delivery tracking
- Retries
- User preferences
- Multiple transports
- Template rendering

AshDispatch complements PubSub - use both!

### Swoosh Directly

Swoosh is the email transport, but doesn't provide:
- Multi-transport support
- Declarative DSL
- Delivery receipts
- Retry logic
- User preferences

AshDispatch uses Swoosh as a transport layer.

## When to Use AshDispatch

**Good Fit:**
- ✅ User-facing notifications (emails, in-app, SMS)
- ✅ Admin alerts and reports
- ✅ Webhook notifications to external systems
- ✅ Audit trails needed
- ✅ User preference management required
- ✅ Multiple delivery channels

**Not a Fit:**
- ❌ Real-time UI updates (use PubSub)
- ❌ High-throughput event streaming (use event sourcing)
- ❌ Complex workflows (use Oban Pro workflows)

## Next Steps

- [Getting Started Tutorial](../tutorials/getting-started.md)
- [Understanding Events](events.md)
- [Delivery Transports](transports.md)

## Implementation Status

AshDispatch is actively being developed. Here's the current status:

### ✅ Complete

- **Resource Extension** - Define events in resources via DSL
- **Event Validation** - Compile-time validation of event configuration
- **Change Injection** - Automatic `DispatchEvent` change injection via transformers
- **DeliveryReceipt Resource** - Full Ash resource with state machine
- **Receipt Persistence** - ETS data layer (override with Postgres)
- **State Tracking** - Receipt status: pending → scheduled → sending → sent/failed
- **Info Module** - Query events: `Info.events(Resource)`, `Info.events_for_action(Resource, :create)`
- **InApp Transport** - Status updates via Ash changesets (notifications mocked)
- **Email Transport** - Status updates via Ash changesets (Oban jobs mocked)
- **Error Handling** - Graceful failures don't break actions
- **Test Coverage** - 37 tests, 100% passing

### 🚧 In Progress

- **Notification Resource** - Creating real Notification records for in-app transport
- **Recipient Resolution** - Admin/user lookup helpers
- **Template System** - HEEx template rendering for emails

### 📋 Planned

- **Oban Integration** - Real job enqueueing for async delivery
- **Email Sending** - Swoosh integration for actual email delivery
- **User Preferences** - Opt-out support per notification category
- **Retry System** - Automatic retry cron job for failed deliveries
- **Remaining Transports** - Discord, Slack, SMS, Webhook implementations
- **Domain Extension** - Counter definitions for real-time UI updates
- **Migration Guide** - Converting existing event modules to AshDispatch

### Data Layer Flexibility

AshDispatch uses ETS by default (in-memory), perfect for:
- ✅ Development and testing
- ✅ Standalone extensions
- ✅ Fast iteration

For production, override with Postgres in your app:

```elixir
# In your app's DeliveryReceipt resource
defmodule MyApp.Deliveries.DeliveryReceipt do
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer
    
  # Inherit attributes from AshDispatch.Resources.DeliveryReceipt
  # Add your own relationships, policies, calculations, etc.
end
```

## Learn More

- [Getting Started Tutorial](../tutorials/getting-started.md) - Build your first event
- [DSL Reference](../dsls/DSL-AshDispatch-Resource.md) - Complete DSL documentation
- [Architecture Guide](architecture.md) - Deep dive into internals

