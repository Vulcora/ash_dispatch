# Generators & Setup

AshDispatch provides several generators to integrate with your application. Use `mix ash_dispatch.setup` once for initial setup, then `mix ash_dispatch.gen.event` for each new event.

## Quick Start

```bash
# Initial setup (creates layouts and directory structure)
mix ash_dispatch.setup

# Generate a new event with content-only templates
mix ash_dispatch.gen.event order created --subject "Order skapad"

# Generate TypeScript SDK and counter types
mix ash_dispatch.gen
```

---

## Setup Task

Run once when first integrating AshDispatch:

```bash
mix ash_dispatch.setup
```

### What It Creates

```
priv/ash_dispatch/
├── layouts/
│   ├── email.html.heex    # Your branded email layout
│   └── email.text.eex     # Plain text email layout
└── templates/             # Your event templates go here
```

### Customizing Layouts

After setup, edit the layouts to match your brand:

```heex
<!-- priv/ash_dispatch/layouts/email.html.heex -->
<!DOCTYPE html>
<html>
  <head><title><%= @subject %></title></head>
  <body>
    <!-- Your header with logo, brand colors -->
    <header>
      <img src="your-logo.png" />
      <h1><%= @subject %></h1>
    </header>

    <!-- Event content injected here -->
    <%= @inner_content %>

    <!-- Your footer with contact info -->
    <footer>
      Your Company | support@example.com
    </footer>
  </body>
</html>
```

All event templates will automatically use this layout.

---

## Event Generator

Generate events with content-only templates:

```bash
mix ash_dispatch.gen.event RESOURCE EVENT [options]
```

### Options

- `--subject` - Email subject line (required)
- `--trigger` - Action that triggers the event (default: event name)
- `--audience` - `user`, `admin`, or `both` (default: `user`)
- `--channels` - Comma-separated: `in_app,email` (default: `in_app,email`)
- `--title` - In-app notification title
- `--message` - In-app notification message

### Examples

```bash
# User-facing order notification
mix ash_dispatch.gen.event order created \
  --subject "Din order har skapats" \
  --title "Order skapad" \
  --message "Order {{order_number}} har registrerats"

# Admin notification for new tickets
mix ash_dispatch.gen.event ticket created \
  --subject "Nytt supportärende" \
  --audience both \
  --title "Nytt ärende" \
  --message "Ärende från {{user_email}}"

# Event with custom trigger action
mix ash_dispatch.gen.event reseller_request accepted \
  --trigger accept \
  --subject "Välkommen!"
```

### Output

The generator creates:

1. **Content-only templates** in `priv/ash_dispatch/templates/{resource}/{event}/`
2. **Inline DSL code** to paste into your resource

```
priv/ash_dispatch/templates/order/created/
├── email.html.heex      # Just the content (no HTML/body/header)
└── email.text.eex       # Plain text content
```

And prints inline DSL:

```elixir
# Add this to your resource's dispatch block:
dispatch do
  event :created,
    trigger_on: :created,
    data_key: :order,
    channels: [
      [transport: :in_app, audience: :user, ...],
      [transport: :email, audience: :user, ...]
    ]
end
```

### Content-Only Templates

Templates only contain event-specific content. The layout handles structure:

```heex
<!-- priv/ash_dispatch/templates/order/created/email.html.heex -->
<p>Hej <strong><%= @display_name %></strong>,</p>

<p>Tack för din beställning!</p>

<div style="background: #f0f9ff; padding: 20px;">
  <h2>Orderdetaljer</h2>
  <p>Ordernummer: <%= @order_number %></p>
</div>

<a href={@order_url}>Visa order →</a>
```

No DOCTYPE, html, head, body, header, or footer needed - the layout provides all that.

---

## Transport-Specific Layouts

Layouts are discovered automatically by transport name. Each transport can have its own layout and format.

### How It Works

```
priv/ash_dispatch/layouts/
├── email.html.heex     # HTML layout for :email transport
├── email.text.eex      # Text layout for :email transport
├── sms.text.eex        # Text layout for :sms transport (if added)
└── discord.md.eex      # Markdown layout for :discord transport (if added)
```

The template resolver looks for: `{transport}.{extension}` where extension comes from format.

### Format Extensions

Configure custom formats for new transports:

```elixir
# config/config.exs
config :ash_dispatch,
  format_extensions: %{
    # Defaults (already included):
    # html: "html.heex",
    # text: "text.eex",

    # Custom formats:
    markdown: "md.eex"     # For Discord/Slack
    # json: "json.eex"     # For webhooks
  }
```

### Adding a New Transport (e.g., SMS)

1. **Create layout** at `priv/ash_dispatch/layouts/sms.text.eex`:
```eex
<%= @subject %>

<%= @inner_content %>

---
Sent from MyApp
```

2. **Create templates** for each event at `priv/ash_dispatch/templates/order/created/sms.text.eex`:
```eex
Order <%= @order_number %> confirmed!
Track at: <%= @order_url %>
```

3. **Add channel** to your event:
```elixir
channels: [
  [transport: :sms, audience: :user, format: :text]
]
```

### Adding Discord with Markdown

1. **Add format config**:
```elixir
config :ash_dispatch,
  format_extensions: %{markdown: "md.eex"}
```

2. **Create layout** at `priv/ash_dispatch/layouts/discord.md.eex`:
```markdown
**<%= @subject %>**

<%= @inner_content %>
```

3. **Create templates** at `priv/ash_dispatch/templates/order/created/discord.md.eex`:
```markdown
🎉 New order **<%= @order_number %>** from <%= @display_name %>!
```

### Custom Layouts Per Channel

Override the layout for specific channels using the `layout` option:

```elixir
channels: [
  # Default layout
  [transport: :email, audience: :user],

  # Custom "urgent" layout for cancelled orders
  [transport: :email, audience: :user, layout: "urgent"],

  # Discord still uses default layout
  [transport: :discord, audience: :admin]
]
```

Layout structure:
```
priv/ash_dispatch/layouts/
├── email.html.heex          # Default email layout
├── email.text.eex           # Default text layout
├── discord.md.eex           # Default Discord layout
└── urgent/
    ├── email.html.heex      # Urgent email (red header)
    └── email.text.eex       # Urgent text
```

The `layout` option is a subdirectory prefix. It tries `layouts/urgent/email.html.heex` first, then falls back to `layouts/email.html.heex` if not found.

**Use cases:**
- Warning/error emails with different header colors
- Admin notifications with different branding
- Promotional emails with special styling

---

## Unified Generator

The `mix ash_dispatch.gen` command generates TypeScript SDK and counter types:

```bash
# Generate everything
mix ash_dispatch.gen

# Generate specific parts
mix ash_dispatch.gen --only sdk
mix ash_dispatch.gen --only counters
mix ash_dispatch.gen --only events
```

## What Gets Generated

### TypeScript SDK (7 files)

The generator creates a complete TypeScript SDK for real-time updates:

```
lib/ash-dispatch/
├── index.ts              # Re-exports everything
├── types.ts              # Counter type definitions
├── store.ts              # Zustand store for counters
├── channel.ts            # Phoenix channel utilities
└── hooks/
    ├── use-channel.ts    # WebSocket connection hook
    ├── use-counter.ts    # Single counter access
    └── use-notifications.ts  # Notification management
```

### Counter Types

Type-safe counter definitions for your frontend:

```typescript
// Generated counters.ts
export type CounterName =
  | "pending_orders"
  | "cart_items"
  | "unread_notifications"
  | "admin_pending_requests"

export const ALL_COUNTERS: CounterName[] = [...]
export const DEFAULT_COUNTERS: AllCounters = {...}
```

### Event Module Stubs (Optional)

If configured, generates event.ex files with the AshDispatch.Event behaviour:

```elixir
defmodule MyApp.Events.Orders.Created.Event do
  use AshDispatch.Event

  @impl true
  def channels(_context) do
    [
      %{transport: :in_app, audience: :user},
      %{transport: :email, audience: :user}
    ]
  end

  # ... more callbacks with TODOs
end
```

---

## Configuration

### Required Configuration

```elixir
# config/config.exs

# Path derivation from ash_typescript
config :ash_typescript,
  output_file: "apps/frontend/src/lib/ash_rpc.ts"

# SDK will generate to: apps/frontend/src/lib/ash-dispatch/
```

### Optional Configuration

```elixir
config :ash_dispatch,
  # Enable/disable SDK generation
  generate_sdk: true,                    # default: true

  # Folder name for SDK (next to ash_rpc.ts)
  sdk_folder: "ash-dispatch",            # default: "ash-dispatch"

  # Event module generation
  events_namespace: MyApp.Events,        # Module prefix for events
  templates_path: "lib/my_app/events"    # Where events go
```

---

## Usage

### Full Generation

Generate everything at once:

```bash
mix ash_dispatch.gen
```

Output:
```
📊 Generating counter types...
  ✓ apps/frontend/src/lib/counters.ts (13 counters)

🔧 Generating TypeScript SDK...
  ✓ Generated 7 SDK files

📝 Generating event module stubs...
  No events found in resources

📄 Extracting templates...
  Template extraction not yet implemented

──────────────────────────────────────────────────
Generation Summary
──────────────────────────────────────────────────
✓ counters: apps/frontend/src/lib/counters.ts
✓ sdk: apps/frontend/src/lib/ash-dispatch
✓ events: 0 event modules
✓ templates: 0 templates
```

### Partial Generation

Generate only what you need:

```bash
# Just counter types (fastest)
mix ash_dispatch.gen --only counters

# Just TypeScript SDK
mix ash_dispatch.gen --only sdk

# Just event stubs
mix ash_dispatch.gen --only events
```

### Custom Output Paths

Override default paths:

```bash
# Custom counters location
mix ash_dispatch.gen --counters-output lib/frontend/types/counters.ts

# Custom SDK location
mix ash_dispatch.gen --sdk-output lib/frontend/ash-dispatch
```

### Force Regeneration

Overwrite existing event stubs:

```bash
mix ash_dispatch.gen --only events --force
```

---

## Generated SDK Usage

### Frontend Setup

```typescript
// app/providers.tsx
import { useChannel, useCounterStore } from '@/lib/ash-dispatch'

export function Providers({ children }) {
  const userChannel = useUserChannel(userId)

  useChannel({
    channel: userChannel,
    onNotification: (notification) => {
      toast.success(notification.title)
    }
  })

  return <>{children}</>
}
```

### Using Counters

```typescript
import { useCounter } from '@/lib/ash-dispatch'

function CartIcon() {
  const cartItems = useCounter('cart_items')

  return (
    <Badge count={cartItems}>
      <ShoppingCart />
    </Badge>
  )
}
```

### Using the Store Directly

```typescript
import { useCounterStore } from '@/lib/ash-dispatch'

function Dashboard() {
  const counters = useCounterStore(state => state.counters)

  return (
    <div>
      <span>Orders: {counters.pending_orders}</span>
      <span>Tickets: {counters.active_tickets}</span>
    </div>
  )
}
```

### Type Safety

The generated types ensure you only use valid counter names:

```typescript
import type { CounterName } from '@/lib/ash-dispatch'

// ✅ Type-safe
const count = useCounter('cart_items')

// ❌ Type error: "invalid_counter" is not assignable to CounterName
const invalid = useCounter('invalid_counter')
```

---

## Backend Integration

### UserChannel Macro (Recommended)

For minimal backend setup, use the UserChannel macro:

```elixir
defmodule MyAppWeb.UserChannel do
  use AshDispatch.Phoenix.UserChannel,
    endpoint: MyAppWeb.Endpoint
end
```

That's it! 3 lines for a complete real-time channel with:
- Counter broadcasting
- Notification pushing
- Initial state loading

See [Phoenix Integration](phoenix-integration.md#userchannel-macro) for customization options.

---

## Counter Discovery

The generator automatically discovers counters from your resource DSL:

```elixir
# In your resource
defmodule MyApp.Orders.ProductOrder do
  use Ash.Resource, extensions: [AshDispatch.Resource]

  dispatch do
    counters do
      counter :pending_orders,
        trigger_on: [:create, :complete],
        query_filter: [status: :pending],
        audience: :user
    end
  end
end
```

These become TypeScript types and Zustand store keys automatically.

---

## Workflow Integration

### Development Flow

1. Define counters in resource DSL
2. Run `mix ash_dispatch.gen`
3. Import hooks in frontend
4. Use counters with full type safety

### CI/CD

Add to your build pipeline:

```yaml
- name: Generate AshDispatch SDK
  run: mix ash_dispatch.gen --only counters --only sdk
```

### Compile Hook (Coming Soon)

Future version will warn when SDK is stale:

```
warning: AshDispatch SDK is stale. Run `mix ash_dispatch.gen`
```

---

## Troubleshooting

### "No counters found"

**Cause:** No resources with counter definitions in configured domains.

**Solution:** Ensure domains are configured:
```elixir
config :ash_dispatch,
  domains: [MyApp.Orders, MyApp.Tickets]
```

### SDK path incorrect

**Cause:** `ash_typescript.output_file` not configured.

**Solution:** Set the output path:
```elixir
config :ash_typescript,
  output_file: "apps/frontend/src/lib/ash_rpc.ts"
```

### Event stubs not generating

**Cause:** `events_namespace` not configured.

**Solution:**
```elixir
config :ash_dispatch,
  events_namespace: MyApp.Events,
  templates_path: "lib/my_app/events"
```

---

## Replaces

The unified generator replaces these older commands:

| Old Command | Now Part Of |
|-------------|-------------|
| `mix ash_dispatch.gen.counter_types` | `mix ash_dispatch.gen --only counters` |
| `mix ash_dispatch.extract_templates` | `mix ash_dispatch.gen --only templates` |
| Manual event.ex creation | `mix ash_dispatch.gen --only events` |

---

## Next Steps

- [Phoenix Integration](phoenix-integration.md) - UserChannel macro setup
- [Counter Broadcasting](counter-broadcasting.md) - Define counters in resources
- [App Integration](app-integration.md) - Complete integration guide
