# Generators & Setup

AshDispatch provides generators to integrate with your application. Use `mix ash_dispatch.setup` once for initial setup, then define events in your resource DSL and run `mix ash_dispatch.gen` to generate missing files.

## Quick Start

```bash
# Initial setup (creates layouts and directory structure)
mix ash_dispatch.setup

# Generate missing templates, event modules, and TypeScript types
mix ash_dispatch.gen

# Or use the unified Ash codegen command
mix ash.codegen
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

## Defining Events in DSL

Events are defined directly in your resource using the `dispatch do` block:

```elixir
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
        channel :email, :admin,
          variant: :admin,
          subject: "Ny order inkommit"
      end
    end
  end
end
```

### DSL Options

| Option | Description |
|--------|-------------|
| `module` | Event module that handles template assigns and recipients |
| `trigger_on` | Actions that trigger this event (`:create`, `:update`, etc.) |
| `data_key` | Key used for the resource in template assigns |
| `channels` | List of delivery channels (in-app, email, SMS, etc.) |

### Channel Options

| Option | Description |
|--------|-------------|
| `:in_app` | Creates a notification in the database |
| `:email` | Sends an email using templates |
| `audience` | `:user`, `:admin`, or `:system` |
| `variant` | Template variant (e.g., `:admin` uses `email.admin.html.heex`) |
| `title` | In-app notification title |
| `message` | In-app notification message |
| `subject` | Email subject line |

## Generating Missing Files

After defining events in DSL, run the generator to create missing templates and event modules:

```bash
# Generate all missing files
mix ash_dispatch.gen

# Or via unified Ash codegen
mix ash.codegen

# Preview what would be generated
mix ash_dispatch.gen --dry-run

# CI check - fail if files need generation
mix ash_dispatch.gen --check
```

### What Gets Generated

For each event with an `:email` channel, the generator creates:

```
lib/my_app/orders/events/created/
├── event.ex                 # Event module (if module option specified but file missing)
└── templates/
    ├── email.html.heex      # HTML email content
    ├── email.text.eex       # Plain text email content
    ├── email.admin.html.heex  # If variant: :admin channel exists
    └── email.admin.text.eex
```

### Content-Only Templates

Templates only contain event-specific content. The layout (from `priv/ash_dispatch/layouts/`) handles structure:

```heex
<!-- lib/my_app/orders/events/created/templates/email.html.heex -->
<p>Hej <strong><%= @display_name %></strong>,</p>

<p>Tack för din beställning!</p>

<div style="background: #f0f9ff; padding: 20px;">
  <h2>Orderdetaljer</h2>
  <p>Ordernummer: <%= @order_number %></p>
</div>

<a href={@source_url}>Visa order →</a>
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

## TypeScript SDK Generation

The `mix ash_dispatch.gen` command generates a complete TypeScript SDK based on your DSL definitions:

```bash
# Generate all missing files (templates, event modules, SDK)
mix ash_dispatch.gen

# Preview what would be generated
mix ash_dispatch.gen --dry-run

# CI check - fail if files need generation
mix ash_dispatch.gen --check
```

## What Gets Generated

### TypeScript SDK (8 files)

The generator creates a complete TypeScript SDK for real-time updates:

```
lib/ash-dispatch/
├── index.ts              # Re-exports everything
├── types.ts              # Counter types, defaults, metadata, accessors
├── events.ts             # Event ID types and metadata
├── store.ts              # Zustand store for counters
├── channel.ts            # Phoenix channel utilities
└── hooks/
    ├── use-channel.ts    # WebSocket connection hook
    ├── use-counter.ts    # Single counter access
    └── use-notifications.ts  # Notification management
```

### Counter Types (types.ts)

Type-safe counter definitions for your frontend:

```typescript
// Generated types.ts
export type CounterName =
  | "pending_orders"
  | "cart_items"
  | "unread_notifications"
  | "admin_pending_requests"

export const DEFAULT_COUNTERS: AllCounters = {...}
export const COUNTER_METADATA = {...}

export function isValidCounter(name: string): name is CounterName
export function getCounterAccessors(counters: AllCounters): CounterAccessors
```

### Event Types (events.ts)

Type-safe event definitions for frontend event handling:

```typescript
// Generated events.ts
export type EventId =
  | "orders.created"
  | "orders.completed"
  | "tickets.created"

export const EVENT_METADATA = {
  "orders.created": {
    domain: "orders",
    channels: [{ transport: "email", audience: "user" }],
  },
  // ...
} as const;

export function isValidEventId(id: string): id is EventId
```

### Event Module Stubs

If an event specifies a `module` option but the file doesn't exist, the generator creates a stub:

```elixir
defmodule MyApp.Orders.Events.Created.Event do
  use AshDispatch.Event

  # Override callbacks to customize behavior:
  # @impl true
  # def prepare_template_assigns(context, channel) do
  #   %{order_number: context.data.order.order_number}
  # end
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
  # Override SDK output path
  sdk_output_path: "apps/frontend/src/lib/ash-dispatch",

  # Domains to scan for counters/events
  domains: [MyApp.Orders, MyApp.Tickets, MyApp.Notifications]
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
* creating apps/frontend/src/lib/ash-dispatch/types.ts
* creating apps/frontend/src/lib/ash-dispatch/events.ts
* creating apps/frontend/src/lib/ash-dispatch/store.ts
* creating apps/frontend/src/lib/ash-dispatch/channel.ts
* creating apps/frontend/src/lib/ash-dispatch/index.ts
* creating apps/frontend/src/lib/ash-dispatch/hooks/use-channel.ts
* creating apps/frontend/src/lib/ash-dispatch/hooks/use-counter.ts
* creating apps/frontend/src/lib/ash-dispatch/hooks/use-notifications.ts

Generated 8 file(s)
```

### Incremental Updates

The generator only creates missing files. When you add new counters or events to your DSL,
run `mix ash_dispatch.gen` again to update `types.ts` and `events.ts`:

```bash
# After adding new counters/events
mix ash_dispatch.gen

# Output shows only changed files:
* creating apps/frontend/src/lib/ash-dispatch/types.ts

Generated 1 file(s)
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
  run: mix ash_dispatch.gen --check
```

The `--check` flag exits with error if any files need generation, ensuring your SDK stays in sync with DSL definitions.

---

## Troubleshooting

### "No counters found"

**Cause:** No resources with counter definitions in configured domains.

**Solution:** Ensure domains are configured:
```elixir
# config/config.exs
config :my_app,
  ash_domains: [MyApp.Orders, MyApp.Tickets]

# Or explicitly in ash_dispatch
config :ash_dispatch,
  domains: [MyApp.Orders, MyApp.Tickets]
```

### SDK path incorrect / not generating

**Cause:** `ash_typescript.output_file` not configured.

**Solution:** Set the output path:
```elixir
config :ash_typescript,
  output_file: "apps/frontend/src/lib/ash_rpc.ts"
```

The SDK will generate to `apps/frontend/src/lib/ash-dispatch/`.

### Templates not generating

**Cause:** Events don't have `:email` channels defined, or the templates already exist.

**Solution:** Ensure your event DSL includes email channels:
```elixir
dispatch do
  event :created do
    channels do
      channel :email, :user, subject: "Order created"
    end
  end
end
```

---

## Next Steps

- [Phoenix Integration](phoenix-integration.md) - UserChannel macro setup
- [Counter Broadcasting](counter-broadcasting.md) - Define counters in resources
- [App Integration](app-integration.md) - Complete integration guide
