# Code Generation

AshDispatch provides a smart code generator that introspects your DSL definitions and generates missing files. It integrates seamlessly with `mix ash.codegen` for a unified development workflow.

## Quick Start

```bash
# Generate missing files (templates, TypeScript types)
mix ash.codegen

# Preview what would be generated
mix ash.codegen --dry-run

# CI check - fail if files need generation
mix ash.codegen --check
```

Or run the generator directly:

```bash
mix ash_dispatch.gen
mix ash_dispatch.gen --dry-run
mix ash_dispatch.gen --check
```

---

## What Gets Generated

### Email Templates

For each event with an `:email` channel, the generator creates:

| File | Description |
|------|-------------|
| `email.html.heex` | HTML email template |
| `email.text.eex` | Plain text email template |

For channels with a `variant` option (e.g., `variant: :admin`):

| File | Description |
|------|-------------|
| `email.admin.html.heex` | Admin-specific HTML template |
| `email.admin.text.eex` | Admin-specific text template |

Templates are placed in the `templates/` subdirectory of the event module:

```
lib/my_app/orders/events/created/
├── event.ex
└── templates/
    ├── email.html.heex
    ├── email.text.eex
    ├── email.admin.html.heex    # if variant: :admin channel exists
    └── email.admin.text.eex
```

### TypeScript Types

When `ash_typescript` is configured, generates `events.ts` with:

- `EventId` - Union type of all event IDs
- `EVENT_METADATA` - Constant with event metadata (domain, channels)
- `Transport` and `Audience` types
- `isValidEventId()` - Type guard function

```typescript
// Auto-generated - apps/frontend/src/lib/ash-dispatch/events.ts

export type EventId =
  | "orders.created"
  | "orders.completed"
  | "tickets.created";

export const EVENT_METADATA = {
  "orders.created": {
    domain: "orders",
    channels: [
      { transport: "email", audience: "user" },
      { transport: "email", audience: "admin", variant: "admin" },
    ],
  },
  // ...
} as const;

export function isValidEventId(id: string): id is EventId {
  return id in EVENT_METADATA;
}

export type Transport = "email" | "in_app" | "sms" | "webhook" | "discord" | "slack";
export type Audience = "user" | "admin" | "system";
```

---

## Configuration

### TypeScript Output Path

The generator automatically derives the TypeScript output path from your `ash_typescript` configuration:

```elixir
# config/config.exs
config :ash_typescript,
  output_file: "apps/frontend/src/lib/ash_rpc.ts"

# AshDispatch will generate to:
# apps/frontend/src/lib/ash-dispatch/events.ts
```

To override the default location:

```elixir
config :ash_dispatch,
  typescript_events_output: "apps/frontend/src/lib/custom/events.ts"
```

### Template Compilation (Production)

Templates are loaded directly from `lib/` in development for fast iteration.

**For production releases**, you must enable template compilation because `lib/` source
files are not included in releases - only `priv/` is bundled:

```elixir
# config/prod.exs - REQUIRED for releases
config :ash_dispatch,
  compile_templates: true
```

This copies templates to `priv/ash_dispatch/templates/` with a manifest, ensuring
template rendering (emails, previews) works in production.

---

## How It Works

### Event Discovery

The generator introspects all resources with the `AshDispatch.Resource` extension:

```elixir
defmodule MyApp.Orders.ProductOrder do
  use Ash.Resource,
    extensions: [AshDispatch.Resource]

  dispatch do
    event :created do
      module MyApp.Orders.Events.Created.Event
      trigger_on [:create]
      channels do
        channel :email, :user
        channel :email, :admin, variant: :admin
        channel :in_app, :user
      end
    end
  end
end
```

From this DSL, the generator:

1. Identifies all events across all resources
2. Checks which templates are required based on channels
3. Compares against existing files
4. Generates only what's missing

### Template Requirements

| Channel Type | Required Templates |
|--------------|-------------------|
| `:email` | `email.html.heex`, `email.text.eex` |
| `:email` with variant | + `email.{variant}.html.heex`, `email.{variant}.text.eex` |
| `:sms` | `sms.text.eex` |
| `:in_app` | None (content in DSL) |
| `:webhook` | None (computed) |
| `:discord` | None (computed) |
| `:slack` | None (computed) |

---

## CLI Options

### `--dry-run`

Preview what would be generated without writing files:

```bash
$ mix ash_dispatch.gen --dry-run

Templates to generate:
  lib/my_app/orders/events/created/templates/email.html.heex
  lib/my_app/orders/events/created/templates/email.text.eex

TypeScript types to generate:
  apps/frontend/src/lib/ash-dispatch/events.ts

3 file(s) would be generated.
```

### `--check`

Exit with error if files need generation. Useful for CI:

```bash
# In CI pipeline
mix ash.codegen --check
```

If files are missing, raises `Ash.Error.Framework.PendingCodegen` with instructions.

### `--verbose`

Show detailed output including event count:

```bash
$ mix ash_dispatch.gen --dry-run --verbose
Found 12 events

Templates to generate:
  ...
```

---

## Integration with `mix ash.codegen`

AshDispatch automatically integrates with Ash's unified codegen command. When you run:

```bash
mix ash.codegen
```

It runs all extension codegens in sequence:

```
Running codegen for AshTypescript.Rpc...
Running codegen for AshDispatch.Resource...
Running codegen for AshPostgres.DataLayer...
```

This means you get:
- TypeScript RPC types
- AshDispatch templates and event types
- Database migrations

All in one command.

---

## Generated Template Content

Generated templates include helpful starter content:

### HTML Email Template

```heex
<%# Template for: orders.created %>
<%# Transport: email, Format: html %>

<p style="margin: 0 0 20px 0; font-size: 16px; line-height: 1.6; color: #374151;">
  Hej<%= if assigns[:display_name], do: " <strong>#{@display_name}</strong>", else: "" %>,
</p>

<p style="margin: 0 0 20px 0; font-size: 16px; line-height: 1.6; color: #374151;">
  TODO: Add your email content here.
</p>

<!-- CTA Button -->
<table width="100%" cellpadding="0" cellspacing="0" style="margin: 30px 0;">
  <tr>
    <td align="center">
      <a href={@source_url} style="display: inline-block; background: linear-gradient(135deg, #2563eb 0%, #1d4ed8 100%); color: #ffffff; padding: 16px 40px; text-decoration: none; border-radius: 6px; font-weight: 600; font-size: 16px;">
        Visa detaljer
      </a>
    </td>
  </tr>
</table>
```

### Text Email Template

```eex
<%# Template for: orders.created %>
<%# Transport: email, Format: text %>

Hej<%= if assigns[:display_name], do: " #{@display_name}", else: "" %>!

TODO: Add your plain text email content here.

Visa detaljer: <%= @source_url %>
```

---

## Troubleshooting

### "No events found"

**Problem:** Generator reports 0 events.

**Causes:**
1. No resources with `AshDispatch.Resource` extension
2. No `dispatch do` blocks in resources
3. Resources not in configured Ash domains

**Solution:**
```elixir
# Ensure your app has ash_domains configured
config :my_app, :ash_domains, [
  MyApp.Orders,
  MyApp.Accounts,
  MyApp.Tickets
]

# Ensure resources use the extension
use Ash.Resource,
  extensions: [AshDispatch.Resource]
```

### "TypeScript not generated"

**Problem:** No TypeScript output despite having events.

**Causes:**
1. `ash_typescript` not configured
2. No `output_file` in ash_typescript config

**Solution:**
```elixir
# config/config.exs
config :ash_typescript,
  output_file: "apps/frontend/src/lib/ash_rpc.ts"
```

### Templates in wrong location

**Problem:** Templates generated to unexpected path.

**Cause:** Event module path determines template location.

**Solution:** Ensure your event modules follow the convention:
```
lib/my_app/{domain}/events/{event_name}/event.ex
```

Templates will be generated to:
```
lib/my_app/{domain}/events/{event_name}/templates/
```

---

## Next Steps

- [Phoenix Integration](phoenix-integration.md) - Set up real-time channels
- [Counter Broadcasting](counter-broadcasting.md) - Define real-time counters
- [User Preferences](user-preferences.md) - Configure notification preferences
