# Architecture & Centralized Modules

This guide explains AshDispatch's internal architecture and the centralized modules that ensure consistent behavior throughout the library.

## Design Principles

AshDispatch follows these key principles:

1. **Single Source of Truth** - Each piece of logic lives in one place
2. **Safe Callback Execution** - All event callbacks are called with error handling
3. **Consistent Defaults** - Default values defined in one place, not scattered
4. **Discoverability** - All configuration options documented together

## Centralized Modules

### AshDispatch.Config

**Purpose:** Centralized configuration access for all AshDispatch settings.

**Problem solved:** Configuration lookups were scattered across 30+ files, each potentially with different default values.

**Usage:**

```elixir
# Instead of:
Application.get_env(:ash_dispatch, :user_module)

# Use:
AshDispatch.Config.user_module()
```

**Key functions:**

| Function | Purpose | Default |
|----------|---------|---------|
| `user_module()` | User resource for recipient resolution | `nil` |
| `domains()` | Ash domains with dispatch-enabled resources | `[]` |
| `delivery_receipt_resource()` | Receipt tracking resource | `AshDispatch.Resources.DeliveryReceipt` |
| `notification_resource()` | In-app notification resource | `AshDispatch.Resources.Notification` |
| `default_from_email()` | Fallback email sender | `"noreply@example.com"` |
| `email_backend()` | Email sending backend | `nil` |

**When to use:**
- Always use `Config` functions instead of `Application.get_env(:ash_dispatch, ...)` in runtime code
- Exception: Mix tasks may need `Application.get_env` for compile-time access

---

### AshDispatch.EventResolver

**Purpose:** Safe execution of event module callbacks with consistent error handling.

**Problem solved:** Direct callback invocations (`module.recipients(context, channel)`) could crash if the function wasn't exported or raised an error.

**Usage:**

```elixir
# Instead of:
module.recipients(context, channel)

# Use:
EventResolver.recipients(module, context, channel)

# For custom callbacks with defaults:
EventResolver.call_if_exported(module, :custom_callback, [arg1, arg2], default: [])
```

**Key functions:**

| Function | Purpose |
|----------|---------|
| `find_module(event_id)` | Find event module by ID |
| `all_events()` | Get all registered events |
| `call_if_exported(module, function, args, opts)` | Safely call any callback |
| `sample_data(module)` | Get preview data |
| `subject(module, context, channel)` | Get email subject |
| `from(module, context, channel)` | Get from address |
| `recipients(module, context, channel)` | Get recipients |
| `prepare_template_assigns(module, context, channel)` | Get template assigns |

**Features:**
- Checks `function_exported?` before calling
- Wraps calls in `try/rescue` for error safety
- Returns sensible defaults when callback missing or fails
- Logs errors at debug level for troubleshooting

---

### AshDispatch.ReceiptStatus

**Purpose:** Centralized receipt status management for all delivery workers.

**Problem solved:** Receipt status update logic was duplicated across multiple workers (email, webhook, etc.), each with slightly different implementations.

**Usage:**

```elixir
alias AshDispatch.ReceiptStatus

# In a worker
def perform(%Oban.Job{args: args}) do
  with {:ok, receipt} <- get_receipt(args["receipt_id"]),
       {:ok, receipt} <- ReceiptStatus.mark_sending(receipt),
       {:ok, response} <- do_delivery(receipt) do
    ReceiptStatus.mark_sent(receipt, response)
    :ok
  else
    {:error, reason} ->
      ReceiptStatus.mark_failed(receipt, reason)
      {:error, reason}
  end
end
```

**Status flow:**

```
pending → sending → sent
                  ↘ failed → failed_permanent (after max retries)
        ↘ scheduled (for async transports)
        ↘ skipped (user opted out)
```

**Key functions:**

| Function | Purpose | Returns |
|----------|---------|---------|
| `mark_sending(receipt)` | Delivery in progress | `{:ok, receipt}` or `{:error, changeset}` |
| `mark_sent(receipt, response)` | Delivery successful | Updated receipt (raises on failure) |
| `mark_failed(receipt, reason)` | Delivery failed | Updated receipt (raises on failure) |
| `mark_skipped(receipt, reason)` | Intentionally not sent | Updated receipt (raises on failure) |
| `mark_scheduled(receipt, opts)` | Job enqueued | Updated receipt (raises on failure) |

---

### AshDispatch.ChannelResolver

**Purpose:** Resolve channels for events from DSL or callback sources.

**Problem solved:** Channel resolution logic needed to work with both inline DSL definitions and event module callbacks.

**Usage:**

```elixir
# Resolve all channels for an event
channels = ChannelResolver.resolve(event_id, event_module, context)

# With pre-loaded DSL channels
channels = ChannelResolver.resolve(event_id, event_module, context, dsl_channels: loaded_channels)

# Check if event has specific transport
has_email? = ChannelResolver.has_transport?(event_id, event_module, context, :email)
```

**Resolution priority:**
1. DSL-defined channels (inline in resource)
2. Event module `channels/1` callback
3. Empty list if neither defined

---

### AshDispatch.Helpers.ResourceIntrospection

**Purpose:** Derive configuration automatically by introspecting Ash resources.

**Problem solved:** Counter and recipient resolution needed explicit `user_id_path` configuration for every resource. With introspection, we can derive this automatically from `belongs_to` relationships.

**Usage:**

```elixir
alias AshDispatch.Helpers.ResourceIntrospection

# Derive user_id_path from resource relationships
ResourceIntrospection.derive_user_id_path(MyApp.Orders.Order)
#=> [:user_id]

# Find all user relationships on a resource
ResourceIntrospection.find_user_relationships(MyApp.Tickets.Ticket)
#=> [%{name: :user, source_attribute: :user_id}, ...]

# Check if audience is relationship-based or filter-based
ResourceIntrospection.is_relationship_audience?(:user)
#=> true  (extract from record)

ResourceIntrospection.is_relationship_audience?(:admin)
#=> false (query all matching users)

# Build nested filter from path
ResourceIntrospection.build_user_filter([:cart, :user_id], "user-123")
#=> [cart: [user_id: "user-123"]]

# Parse audience config (used by both counters and events)
ResourceIntrospection.parse_audience_config([:user, {:admin, true}])
#=> {[:user], [admin: true]}

# Extract just the filter portion
ResourceIntrospection.extract_audience_filter([:user, {:admin, true}])
#=> [admin: true]
```

**Key functions:**

| Function | Purpose |
|----------|---------|
| `derive_user_id_path(resource)` | Find user_id field via `belongs_to` relationships |
| `derive_user_id_path(resource, audience)` | Audience-aware derivation (auto-picks matching relationship) |
| `find_user_relationships(resource)` | List all relationships to user module |
| `has_user_relationship?(resource)` | Check if resource relates to user |
| `build_user_filter(path, user_id)` | Build nested filter from path |
| `is_relationship_audience?(audience)` | Check if audience extracts from record |
| `get_audience_relationship(audience)` | Get relationship name for audience |
| `parse_audience_config(config)` | Parse `[:user, {:admin, true}]` → `{path, filter}` |
| `extract_audience_filter(config)` | Get just the filter portion from config |

**Audience Pattern:**

The library distinguishes between two audience types based on configuration format:

```elixir
config :ash_dispatch,
  audiences: [
    :user,                                # Bare atom = relationship-based
    :creator,                             # Extract from :creator relationship
    {:admin, [:user, {:admin, true}]},    # Tuple = filter-based (query all admins)
    {:partner, [:user, {:role, :partner}]}
  ]
```

- **Relationship-based** (`:user`): Extract recipient from record's relationship
- **Filter-based** (`{:admin, ...}`): Query all users matching the filter

**Ambiguity Handling:**

When a resource has multiple `belongs_to` relationships to the user module (e.g., `:user`, `:started_by`, `:resolved_by`), the introspection uses **audience-aware disambiguation**:

1. If `audience` name matches a relationship name (e.g., `audience: :user` and `:user` relationship exists), auto-picks that relationship
2. Otherwise, logs a warning with guidance to add explicit `user_id_path` in counter DSL

```elixir
# Ticket has :user, :started_by, :resolved_by, :closed_by relationships
# With audience: :user, auto-picks :user → [:user_id]

counter :open_tickets,
  audience: :user,  # Matches :user relationship - auto-derived!
  ...

# Admin counters bypass authorization for system-wide totals
counter :admin_open_tickets,
  audience: :admin,
  authorize?: false  # Bypass policies - counts ALL tickets
```

**Three-Layer Counter Control Model:**

| Layer | Option | Purpose |
|-------|--------|---------|
| **Audience** | `audience: :admin` | WHO receives the broadcast |
| **Authorization** | `authorize?: false` | WHAT records the actor CAN see (Ash policies) |
| **Scoping** | `scope: expr(...)` | WHAT subset we WANT to count |

This separation enables powerful, flexible combinations:

```elixir
# User sees their own count (auto-derived scoping via user_id_path)
counter :my_orders, audience: :user

# Admin sees system-wide count (bypass authorization)
counter :all_orders, audience: :admin, authorize?: false

# Admin sees THEIR assigned tickets (custom scope expression)
counter :my_assigned_tickets,
  audience: :admin,
  scope: expr(assigned_to_id == ^actor(:id))

# Regional admin sees orders in their region
counter :regional_orders,
  audience: :admin,
  scope: expr(region == ^actor(:region))
```

**Nested Resources:**

For resources without a direct user relationship (e.g., CartItem → Cart → User):

```elixir
# CartItem only has :cart relationship, not :user
counter :cart_items,
  audience: :user,
  user_id_path: [:cart, :user_id]  # Follow cart → user_id
```

---

### AshDispatch.ContentMap

**Purpose:** Handle mixed atom/string keys in content maps (common with PostgreSQL JSONB).

**Problem solved:** Content stored in JSONB comes back with string keys, but code often uses atom keys. Pattern like `content["field"] || content[:field]` was duplicated everywhere.

**Usage:**

```elixir
import AshDispatch.ContentMap

# Get content regardless of key type
title = get_content(receipt.content, :title)
message = get_content(receipt.content, :message)

# Works with both:
# %{title: "Hello"}
# %{"title" => "Hello"}
```

**Where used:**
- `AshDispatch.Transports.InApp`
- `AshDispatch.Transports.Discord`
- `AshDispatch.Transports.Slack`

---

## Module Relationships

```
┌─────────────────────────────────────────────────────────────────┐
│                         Dispatcher                               │
│  Entry point for all event dispatching                          │
│  Uses: Config, EventResolver, ChannelResolver                   │
└─────────────────────────────────────────────────────────────────┘
                              │
            ┌─────────────────┼─────────────────┐
            ▼                 ▼                 ▼
┌───────────────────┐ ┌──────────────┐ ┌──────────────────────────┐
│    Transports     │ │   Counters   │ │  Helpers                 │
│ Email, InApp, etc │ │ Broadcasting │ │ ResourceIntrospection    │
│ Uses: ContentMap  │ │ Uses: Config │ │ CounterLoader, etc       │
└───────────────────┘ └──────────────┘ └──────────────────────────┘
            │                 │
            ▼                 ▼
┌─────────────────────────────────────────────────────────────────┐
│                         Workers                                  │
│  SendEmail, SendWebhook (Oban jobs)                             │
│  Uses: Config, ReceiptStatus                                    │
└─────────────────────────────────────────────────────────────────┘
```

## Best Practices

### For Library Contributors

1. **Use Config for all configuration access:**
   ```elixir
   # Good
   user_module = Config.user_module()

   # Avoid
   user_module = Application.get_env(:ash_dispatch, :user_module)
   ```

2. **Use EventResolver for callback execution:**
   ```elixir
   # Good - safe with error handling
   subject = EventResolver.subject(module, context, channel)

   # Avoid - crashes if not exported
   subject = module.subject(context, channel)
   ```

3. **Use ReceiptStatus for status updates:**
   ```elixir
   # Good - consistent status management
   ReceiptStatus.mark_sent(receipt, response)

   # Avoid - manual changeset creation
   receipt |> Ash.Changeset.for_update(:mark_sent, %{...}) |> Ash.update!()
   ```

4. **Use ContentMap for JSONB content:**
   ```elixir
   # Good - handles both key types
   title = get_content(content, :title)

   # Avoid - misses string keys
   title = content[:title]
   ```

### For Application Developers

When extending AshDispatch:

1. **Event modules** should use the `AshDispatch.Event` behaviour which handles defaults
2. **Custom transports** should use `Config` and `ReceiptStatus`
3. **Custom workers** should follow the pattern in `SendEmail` and `SendWebhook`

## Troubleshooting

### Debug Configuration

To verify configuration is loaded correctly:

```elixir
# In IEx
AshDispatch.Config.user_module()
AshDispatch.Config.domains()
AshDispatch.Config.email_backend()
```

### Debug Event Resolution

To verify event callbacks are working:

```elixir
# Find an event
{:ok, module} = AshDispatch.EventResolver.find_module("orders.created")

# Check what callbacks are exported
AshDispatch.EventResolver.exports?(module, :recipients, 2)
AshDispatch.EventResolver.exports?(module, :subject, 2)

# Test callback with sample context
context = AshDispatch.EventResolver.build_sample_context("orders.created", module)
subject = AshDispatch.EventResolver.subject(module, context, %AshDispatch.Channel{})
```

### Debug Receipt Status

To check receipt status transitions:

```elixir
# Get a receipt
receipt = AshDispatch.Config.delivery_receipt_resource() |> Ash.get!(receipt_id)

# Check current status
receipt.status

# Try a status transition (use in IEx only)
{:ok, updated} = AshDispatch.ReceiptStatus.mark_sending(receipt)
```

---

## Next Steps

- [Configuration](configuration.md) - All available configuration options
- [Delivery Receipts](delivery-receipts.md) - Receipt management and admin actions
- [Getting Started](../tutorials/getting-started.md) - Build your first event
- [Manual Dispatch](../tutorials/manual-dispatch-and-events.md) - Event modules and preview
