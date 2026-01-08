# DSL: AshDispatch.Resource

The `AshDispatch.Resource` extension adds event dispatching capabilities to Ash resources.

## Table of Contents

- [dispatch](#dispatch) - Top-level section for defining events
  - [event](#dispatch-event) - Define an event that dispatches when actions occur
- [Actor Access](#actor-access) - Accessing the actor (user who triggered the action) in events

---

## dispatch

The `dispatch` section contains event definitions for the resource.

### Usage

```elixir
defmodule MyApp.Orders.ProductOrder do
  use Ash.Resource,
    extensions: [AshDispatch.Resource]

  dispatch do
    event :created, trigger_on: :create_from_cart do
      # event configuration...
    end

    event :cancelled, trigger_on: :cancel do
      # event configuration...
    end
  end
end
```

### Entities

- [event](#dispatch-event)

---

## dispatch.event

Defines an event that is automatically dispatched when specified actions occur.

### Arguments

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `name` | `atom` | ✅ | Unique name for the event (e.g., `:created`, `:updated`, `:cancelled`) |

### Options

| Name | Type | Default | Required | Description |
|------|------|---------|----------|-------------|
| `trigger_on` | `atom \| [atom] \| :manual` | - | ✅ | Action name(s) that trigger this event, or `:manual` for manual-only dispatch |
| `module` | `atom` | `nil` | ❌ | Optional callback module implementing `AshDispatch.Event` behaviour |
| `event_id` | `string` | auto-generated | ❌ | Explicit event ID. Auto-generated as `{resource_name}.{event_name}` if not specified |
| `data_key` | `atom` | `:record` | ❌ | Key to use for the resource in context.data |
| `include_actor_as` | `atom` | `nil` | ❌ | Alias key for the actor in context.data (see [Actor Access](#actor-access)) |
| `manual_trigger_filter` | `keyword` | `nil` | ❌ | Filter for showing event in manual trigger UI (e.g., `[confirmed_at: nil]`) |
| `load` | `[atom]` | `[]` | ❌ | Relationships to preload before dispatching |
| `domain` | `atom` | `nil` | ❌ | Event domain (e.g., `:orders`, `:tickets`). Defaults to resource domain |
| `channels` | `[keyword_list \| map]` | `[]` | ❌ | List of delivery channels for this event |
| `content` | `keyword_list \| map` | `[]` | ❌ | Content configuration (subject, titles, messages) |
| `metadata` | `keyword_list \| map` | `[]` | ❌ | Event metadata (notification type, user configurable, etc.) |

### Examples

#### Simple inline event

```elixir
dispatch do
  event :created,
    trigger_on: :create,
    channels: [
      [transport: :in_app, audience: :user],
      [transport: :email, audience: :user, delay: 300]
    ],
    content: [
      subject: "Order #{{order_number}} created",
      notification_title: "Order Created",
      notification_message: "Your order is being processed"
    ],
    metadata: [
      notification_type: :success,
      user_configurable: true
    ]
end
```

#### Event with callback module

For complex logic, use a callback module:

```elixir
dispatch do
  event :created,
    trigger_on: :create_from_cart,
    module: MyApp.Events.Orders.Created,
    load: [:user, :items]
end
```

#### Multiple trigger actions

```elixir
dispatch do
  event :status_changed,
    trigger_on: [:process, :complete, :cancel],
    channels: [
      [transport: :in_app, audience: :user]
    ],
    content: [
      notification_title: "Status: {{status}}"
    ]
end
```

#### Custom event ID

```elixir
dispatch do
  event :created,
    trigger_on: :create,
    event_id: "ecommerce.order.created",  # Custom ID for external integrations
    channels: [
      [transport: :webhook, audience: :external, webhook_url: "https://..."]
    ]
end
```

#### Event with actor alias

Use `include_actor_as` to give the actor (user who triggered the action) a semantic alias in `context.data`:

```elixir
dispatch do
  # Invitation event - actor is the admin who invited the user
  event :invited,
    trigger_on: :invite,
    data_key: :invited_user,
    include_actor_as: :invited_by,
    module: MyApp.Accounts.Events.Invited,
    channels: [[transport: :email, audience: :user]]

  # Assignment event - actor is the person who assigned
  event :assigned,
    trigger_on: :assign,
    data_key: :ticket,
    include_actor_as: :assigned_by,
    channels: [[transport: :in_app, audience: :user]]
end
```

In your event module or templates, access the actor as:
- `context.data.actor` (always available)
- `context.data.invited_by` or `context.data.assigned_by` (semantic alias)

#### Manual-only events

Use `trigger_on: :manual` for events that are dispatched programmatically via `AshDispatch.Dispatcher.dispatch/3` rather than automatically on actions. This is useful for:

- Events triggered by external systems (AshAuthentication senders)
- Events that need custom context not available in action changes
- Events that should only be triggered from admin UI

```elixir
dispatch do
  # Dispatched by AshAuthentication sender, not auto-triggered
  event :password_reset,
    trigger_on: :manual,
    data_key: :user,
    module: MyApp.Accounts.Events.PasswordReset.Event,
    channels: [[transport: :email, audience: :user]]

  # Only show in manual trigger UI for unconfirmed users
  event :email_confirmation,
    trigger_on: :manual,
    data_key: :user,
    manual_trigger_filter: [confirmed_at: nil],
    module: MyApp.Accounts.Events.EmailConfirmation.Event,
    channels: [[transport: :email, audience: :user]]
end
```

Manual events are still registered in EventRegistry for:
- Preview in admin email template UI
- Manual trigger functionality
- TypeScript type generation

---

## Channels Configuration

Channels define how and where the event is delivered.

### Channel Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `transport` | `atom` | ✅ | Transport type: `:email`, `:in_app`, `:discord`, `:slack`, `:sms`, `:webhook` |
| `audience` | `atom` | ✅ | Who receives this: `:user`, `:admin`, or custom audience |
| `delay` | `integer` | ❌ | Delay in seconds before delivering (default: 0) |
| `policy` | `atom` | ❌ | Delivery policy: `:always` or `:skip_if_read` (default: `:always`) |
| `webhook_url` | `string` | ❌ | Webhook URL (required for `:webhook` transport) |
| `deduplicate_group` | `atom` | ❌ | Group channels for deduplication (see below) |
| `optional` | `boolean` | ❌ | Suppress warnings when no recipients found (default: `false`) |

### Deduplication with `deduplicate_group`

When audiences overlap (e.g., `:admin` and `:stakeholders` both contain some users), a user might receive duplicate notifications. The `deduplicate_group` option lets you control this.

Channels sharing the same `deduplicate_group` are deduplicated - if a user matches multiple audiences in the same group, they receive only ONE notification. The first matching channel (by DSL order) wins.

```elixir
channels: [
  # These two share a group - user in both gets only one in_app notification
  [transport: :in_app, audience: :stakeholders, deduplicate_group: :internal],
  [transport: :in_app, audience: :admin, deduplicate_group: :internal],

  # These share a different group - deduplication applies within this group
  [transport: :email, audience: :admin, deduplicate_group: :admin_emails],
  [transport: :email, audience: :finance, deduplicate_group: :admin_emails],

  # No group = no deduplication - customer always gets notification
  [transport: :in_app, audience: :customer]
]
```

**Important notes:**
- Channels without `deduplicate_group` are never deduplicated
- Deduplication is opt-in (off by default)
- Order matters: first channel in DSL order wins when deduplicating
- Groups are per-transport-agnostic: you can group `:email` and `:in_app` channels together if needed

### Optional Channels

Use `optional: true` when an audience may legitimately have no recipients. This suppresses warnings that would otherwise be logged when recipient resolution returns empty.

**Common use cases:**
- Dynamic audiences that may not exist yet (e.g., `:lead_owner` before a lead is assigned)
- Conditional audiences based on workflow state
- MFA-based audiences that may return empty lists in certain scenarios

```elixir
channels: [
  # Primary notification - always has a recipient
  [transport: :in_app, audience: :user],

  # Optional - lead owner may not be assigned yet
  [transport: :in_app, audience: :lead_owner, optional: true],
  [transport: :email, audience: :lead_owner, optional: true],

  # Optional - KAMs may not exist in the system
  [transport: :in_app, audience: :kam, optional: true]
]
```

When `optional: true` is set, no warning is logged if:
- The MFA resolver function doesn't exist for this audience
- The MFA resolver returns an empty list (no recipients)
- No recipient configuration is found for the audience

**Without `optional: true`**, you'll see warnings like:

When the resolver function returns empty (most common case):
```
[warning] [AshDispatch] Audience resolver for :lead_owner returned no recipients.

The resolver function was called successfully but returned an empty list.
This may be expected (e.g., no lead owner assigned yet).

Tip: To silence this warning, add `optional: true` to the channel:
     [transport: :in_app, audience: :lead_owner, optional: true]
```

When the resolver function doesn't exist:
```
[warning] [AshDispatch] Audience resolver function MyApp.AudienceResolver.lead_owner/1 not found for audience :lead_owner.

The function is not exported. Check that:
1. The module exists and is compiled
2. The function is public (def, not defp)
3. The arity matches the args in your config

Tip: If this audience is expected to have no recipients sometimes, add `optional: true` to the channel:
     [transport: :in_app, audience: :lead_owner, optional: true]
```

### Channel Examples

```elixir
channels: [
  # Immediate in-app notification
  [transport: :in_app, audience: :user],

  # Email after 5 minutes if notification not read
  [transport: :email, audience: :user, delay: 300, policy: :skip_if_read],

  # Immediate email to admins
  [transport: :email, audience: :admin],

  # Discord webhook to team channel
  [transport: :discord, audience: :team, webhook_url: "https://discord.com/api/webhooks/..."],

  # SMS to user (if enabled)
  [transport: :sms, audience: :user]
]
```

---

## Content Configuration

Content defines the message text for notifications and emails.

### Content Fields

| Field | Type | Description |
|-------|------|-------------|
| `subject` | `string` | Email subject line. Supports `{{variable}}` interpolation |
| `notification_title` | `string` | In-app notification title. Supports `{{variable}}` interpolation |
| `notification_message` | `string` | In-app notification message. Supports `{{variable}}` interpolation |
| `action_url` | `string` | URL for notification action button. Supports `{{variable}}` interpolation |

### Variable Interpolation

Use `{{variable_name}}` syntax to insert dynamic values:

```elixir
content: [
  subject: "Order #{{order_number}} - {{status}}",
  notification_title: "Hello {{user_name}}!",
  notification_message: "Created at {{inserted_at}}",
  action_url: "https://app.example.com/orders/{{id}}"
]
```

Variables are resolved from:
1. **Resource fields**: Any attribute on the resource (e.g., `{{id}}`, `{{status}}`)
2. **Preloaded relationships**: Use `load: [...]` option
   - `{{user.name}}` becomes `{{user_name}}`
   - `{{assignee.email}}` becomes `{{assignee_email}}`
3. **Custom assigns**: Via callback module's `prepare_template_assigns/2`

### Content Examples

```elixir
# Simple text
content: [
  notification_title: "Welcome!",
  notification_message: "Thanks for signing up"
]

# With variables
content: [
  subject: "Order #{{order_number}} shipped",
  notification_title: "Order Shipped!",
  notification_message: "Your order to {{shipping_address}} is on its way",
  action_url: "/orders/{{id}}/tracking"
]

# Complex with dates
content: [
  subject: "Ticket #{{id}} resolved",
  notification_message: "Resolved by {{assignee_name}} on {{resolved_at}}"
]
```

---

## Metadata Configuration

Metadata provides additional context about the event.

### Metadata Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `notification_type` | `atom` | `:info` | Type for UI styling: `:info`, `:success`, `:warning`, `:error` |
| `action_required` | `boolean` | `false` | Whether this notification requires user action |
| `user_configurable` | `boolean` | `true` | Whether users can opt out via preferences |

### Metadata Examples

```elixir
# Success notification that users can configure
metadata: [
  notification_type: :success,
  action_required: false,
  user_configurable: true
]

# Critical error that can't be disabled
metadata: [
  notification_type: :error,
  action_required: true,
  user_configurable: false
]

# Info notification
metadata: [
  notification_type: :info,
  user_configurable: true
]
```

---

## Actor Access

When events are triggered by Ash actions, the **actor** (user who performed the action) is automatically included in `context.data`.

### Default Behavior

The actor is always available as `context.data.actor`:

```elixir
def prepare_template_assigns(context, _channel) do
  %{
    performed_by: context.data.actor.name,
    performer_email: context.data.actor.email
  }
end
```

### Semantic Aliases with `include_actor_as`

For clearer code, use `include_actor_as` to add a semantic alias:

```elixir
dispatch do
  event :invited,
    trigger_on: :invite,
    data_key: :invited_user,
    include_actor_as: :invited_by,
    channels: [[transport: :email, audience: :user]]
end
```

Now the actor is available as both:
- `context.data.actor` (always)
- `context.data.invited_by` (alias)

### Common Actor Alias Patterns

| Event Type | Alias | Description |
|------------|-------|-------------|
| Invitation | `:invited_by` | Admin or owner who sent the invite |
| Assignment | `:assigned_by` | User who assigned the task/ticket |
| Approval | `:approved_by` | User who approved the request |
| Cancellation | `:cancelled_by` | User who cancelled the order |
| Comment | `:commented_by` | User who left the comment |

### Using Actor in Templates

In HEEx templates, access the actor via assigns:

```heex
<p>This invitation was sent by <%= @invited_by.name %>.</p>
<p>Contact them at <%= @invited_by.email %> if you have questions.</p>
```

In your event module's `prepare_template_assigns/2`:

```elixir
def prepare_template_assigns(context, _channel) do
  %{
    invited_by: context.data.invited_by,
    invited_user: context.data.invited_user
  }
end
```

---

## Callback Module

For complex events, implement the `AshDispatch.Event` behaviour:

### Required Callbacks

```elixir
@callback channels(context :: Context.t()) :: [Channel.t()]
@callback recipients(context :: Context.t(), channel :: Channel.t()) :: [User.t()]
@callback notification_title(context :: Context.t(), channel :: Channel.t()) :: String.t()
@callback notification_message(context :: Context.t(), channel :: Channel.t()) :: String.t()
```

### Optional Callbacks

```elixir
@callback from_email(context :: Context.t(), channel :: Channel.t()) :: String.t()
@callback subject(context :: Context.t(), channel :: Channel.t()) :: String.t()
@callback render_html_email(context :: Context.t(), channel :: Channel.t()) :: String.t()
@callback render_text_email(context :: Context.t(), channel :: Channel.t()) :: String.t()
@callback prepare_template_assigns(context :: Context.t(), channel :: Channel.t()) :: map()
@callback action_url(context :: Context.t(), channel :: Channel.t()) :: String.t() | nil
@callback metadata(context :: Context.t()) :: map()
```

### Example Callback Module

```elixir
defmodule MyApp.Events.Orders.Created do
  @behaviour AshDispatch.Event

  @impl true
  def channels(_context) do
    [
      %AshDispatch.Channel{transport: :in_app, audience: :user},
      %AshDispatch.Channel{transport: :email, audience: :user, time: {:in, 300}},
      %AshDispatch.Channel{transport: :email, audience: :admin}
    ]
  end

  @impl true
  def recipients(context, channel) do
    case channel.audience do
      :user -> [context.data.order.user]
      :admin -> MyApp.Accounts.list_admins()
    end
  end

  @impl true
  def from_email(_context, _channel), do: "orders@myapp.com"

  @impl true
  def subject(context, _channel) do
    "Order ##{context.data.order.number} created"
  end

  @impl true
  def notification_title(_context, _channel), do: "Order Created"

  @impl true
  def notification_message(context, _channel) do
    "Your order ##{context.data.order.number} is being processed"
  end

  @impl true
  def prepare_template_assigns(context, _channel) do
    order = context.data.order

    %{
      order_number: order.number,
      total: Money.to_string(order.total),
      item_count: length(order.items),
      user_name: order.user.name,
      action_url: "#{context.base_url}/orders/#{order.id}"
    }
  end

  @impl true
  def render_html_email(context, channel) do
    assigns = prepare_template_assigns(context, channel)

    Phoenix.View.render_to_string(
      MyAppWeb.EmailView,
      "order_created.html",
      assigns
    )
  end

  @impl true
  def render_text_email(context, channel) do
    assigns = prepare_template_assigns(context, channel)

    Phoenix.View.render_to_string(
      MyAppWeb.EmailView,
      "order_created.text",
      assigns
    )
  end
end
```

---

## Auto-Dispatch Behavior

When you define events, AshDispatch automatically:

1. **Injects Change**: Adds `AshDispatch.Changes.DispatchEvent` to the action's changes list
2. **Runs After Success**: Change executes only if action succeeds
3. **Creates Receipt**: `DeliveryReceipt` created with full content
4. **Dispatches**: Each channel gets delivered via its transport
5. **Tracks Status**: Receipt status updated through delivery lifecycle

### No Manual Triggering Required

```elixir
# This is all you need - AshDispatch handles the rest!
dispatch do
  event :created, trigger_on: :create, ...
end

# When you create a record:
ProductOrder
|> Ash.Changeset.for_create(:create, params)
|> Ash.create!()

# -> Event automatically dispatches!
# -> Receipts created
# -> Notifications sent
# -> Emails queued
# -> No manual dispatcher calls needed
```

---

## Configuration Requirements

### Required: Oban

AshDispatch uses Oban for async delivery. Configure queues:

```elixir
# config/config.exs
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [
    ash_dispatch_email: 10,
    ash_dispatch_webhook: 5
  ]
```

### Required for Email: Swoosh

```elixir
# config/config.exs
config :my_app, MyApp.Mailer,
  adapter: Swoosh.Adapters.Resend,
  api_key: System.get_env("RESEND_API_KEY")
```

### Optional: Retry Cron

Auto-retry failed deliveries:

```elixir
# config/config.exs
config :my_app, Oban,
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"*/15 * * * *", MyApp.Workers.RetryFailedReceipts}
     ]}
  ]
```

---

## Validation

AshDispatch validates your event configurations at compile time:

### Validated at Compile Time

- ✅ Event names are unique within resource
- ✅ `trigger_on` actions exist in the resource
- ✅ Events have either channels OR a module
- ✅ Channel transport types are valid

### Validation Errors

```elixir
# Duplicate event names
** (Spark.Error.DslError) Duplicate event name: :created

# Non-existent action
** (Spark.Error.DslError) Event :created references non-existent action: :create_order
Available actions: [:create, :update, :destroy]

# Missing configuration
** (Spark.Error.DslError) Event :created has no configuration.
Events must have either:
- Inline channel/content configuration, OR
- A callback module via the `module:` option
```

---

## Advanced Patterns

### Conditional Channels

Use callback module for dynamic channel selection:

```elixir
def channels(context) do
  base_channels = [
    %Channel{transport: :in_app, audience: :user}
  ]

  if urgent?(context.data.order) do
    base_channels ++ [%Channel{transport: :sms, audience: :user}]
  else
    base_channels ++ [%Channel{transport: :email, audience: :user, time: {:in, 3600}}]
  end
end
```

### Multi-Audience Events

```elixir
dispatch do
  event :created,
    trigger_on: :create,
    channels: [
      [transport: :in_app, audience: :user],
      [transport: :email, audience: :user, delay: 300, policy: :skip_if_read],
      [transport: :email, audience: :admin],
      [transport: :discord, audience: :team, webhook_url: "https://..."]
    ]
end
```

### Progressive Notifications

```elixir
dispatch do
  # Immediate notification
  event :created,
    trigger_on: :create,
    channels: [[transport: :in_app, audience: :user]]

  # Follow-up email if not completed
  event :reminder,
    trigger_on: :create,
    channels: [[transport: :email, audience: :user, delay: 86400]],  # 1 day
    content: [subject: "Don't forget to complete your order!"]
end
```

---

## counters

The `counters` section defines real-time counter broadcasts that automatically update frontend UIs when actions occur.

### Usage

```elixir
defmodule MyApp.Orders.ProductOrder do
  use Ash.Resource,
    extensions: [AshDispatch.Resource]

  counters do
    counter :pending_orders,
      trigger_on: [:create, :complete, :cancel],
      query_filter: [status: :pending],
      audience: :user,
      group: :orders,
      invalidates: ["orders"]

    counter :admin_pending_orders,
      trigger_on: [:create, :complete, :cancel],
      query_filter: [status: :pending],
      audience: :admin,
      authorize?: false,
      invalidates: ["orders"]
  end
end
```

### Counter Options

| Name | Type | Default | Required | Description |
|------|------|---------|----------|-------------|
| `trigger_on` | `atom \| [atom]` | - | ✅ | Action name(s) that trigger this counter broadcast |
| `query_filter` | `keyword` | `[]` | ❌ | Static Ash filter for counting (e.g., `[status: :pending]`) |
| `audience` | `atom` | - | ✅ | Who receives broadcasts: `:user`, `:admin`, or custom audience |
| `counter_name` | `atom` | same as name | ❌ | Counter name to broadcast (defaults to DSL name) |
| `invalidates` | `[string]` | `[]` | ❌ | Frontend query keys to invalidate |
| `group` | `atom` | `nil` | ❌ | Counter group for TypeScript generation |
| `authorize?` | `boolean` | `true` | ❌ | Whether to use Ash authorization (policies) |
| `scope` | `Ash.Expr.t()` | `nil` | ❌ | Ash expression for recipient-specific scoping |
| `user_id_path` | `[atom]` | auto-derived | ❌ | Path to user_id for scoping (e.g., `[:cart, :user_id]`) |
| `filter_by_record` | `keyword` | `nil` | ❌ | Filter by triggering record field |
| `aggregate` | `atom` | `nil` | ❌ | Use Ash aggregate instead of query_filter |

### Three-Layer Control Model

Counters use a three-layer control model for maximum flexibility:

| Layer | Option | Purpose |
|-------|--------|---------|
| **Audience** | `audience: :admin` | WHO receives the broadcast |
| **Authorization** | `authorize?: false` | WHAT records actor CAN see (Ash policies) |
| **Scoping** | `scope: expr(...)` | WHAT subset we WANT to count |

### Counter Examples

#### User Counter (Auto-Scoped)

```elixir
counter :my_pending_orders,
  trigger_on: [:create, :complete],
  query_filter: [status: :pending],
  audience: :user,
  invalidates: ["orders"]
```

User counters automatically derive `user_id_path` from the resource's `belongs_to :user` relationship.

#### Admin Counter (System-Wide)

```elixir
counter :admin_pending_orders,
  trigger_on: [:create, :complete],
  query_filter: [status: :pending],
  audience: :admin,
  authorize?: false,  # Bypass policies - count ALL records
  invalidates: ["orders", "analytics"]
```

#### Scoped Counter (Custom Expression)

```elixir
# Regional admin sees only orders in their region
counter :regional_pending_orders,
  trigger_on: [:create, :complete],
  query_filter: [status: :pending],
  audience: :admin,
  scope: expr(region == ^actor(:region)),
  invalidates: ["orders"]

# Admin sees their assigned tickets
counter :my_assigned_tickets,
  trigger_on: [:create, :resolve],
  query_filter: [status: :open],
  audience: :admin,
  scope: expr(assigned_to_id == ^actor(:id)),
  invalidates: ["tickets"]

# Seller sees orders containing their products
counter :seller_orders,
  trigger_on: [:create, :complete],
  query_filter: [status: :pending],
  audience: :seller,
  scope: expr(exists(items, product.seller_id == ^actor(:id))),
  invalidates: ["orders"]
```

#### Nested Resource Counter

```elixir
# CartItem → Cart → User (no direct user relationship)
counter :cart_items,
  trigger_on: [:add_to_cart, :remove_from_cart],
  query_filter: [],
  audience: :user,
  user_id_path: [:cart, :user_id],  # Explicit path
  invalidates: ["cart"]
```

### Scope Expression Templates

The `scope` option accepts any Ash expression with `^actor(:field)` templates:

```elixir
^actor(:id)           # Recipient's ID
^actor(:region)       # Recipient's region attribute
^actor(:team_id)      # Recipient's team_id
^actor([:profile, :org_id])  # Nested path access
```

### scope vs user_id_path

| Feature | `user_id_path` | `scope` |
|---------|----------------|---------|
| Simple user_id | ✅ `[:user_id]` | ✅ `expr(user_id == ^actor(:id))` |
| Nested paths | ✅ `[:cart, :user_id]` | ✅ `expr(cart.user_id == ^actor(:id))` |
| Attribute matching | ❌ | ✅ `expr(region == ^actor(:region))` |
| Relationship traversal | ❌ | ✅ `expr(assigned_support.team_id == ^actor(:team_id))` |
| exists/has_many | ❌ | ✅ `expr(exists(items, ...))` |

**Recommendation:** Use `user_id_path` for simple cases, `scope` for complex filtering.

---

## See Also

- [Getting Started Tutorial](../tutorials/getting-started.md)
- [What is AshDispatch?](../topics/what-is-ash-dispatch.md)
- [Phoenix Integration](../topics/phoenix-integration.md)
- [Counter Broadcasting](../topics/counter-broadcasting.md)
