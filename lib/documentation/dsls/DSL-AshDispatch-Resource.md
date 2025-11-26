# DSL: AshDispatch.Resource

The `AshDispatch.Resource` extension adds event dispatching capabilities to Ash resources.

## Table of Contents

- [dispatch](#dispatch) - Top-level section for defining events
  - [event](#dispatch-event) - Define an event that dispatches when actions occur

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
| `trigger_on` | `atom \| [atom]` | - | ✅ | Action name(s) that trigger this event |
| `module` | `atom` | `nil` | ❌ | Optional callback module implementing `AshDispatch.Event` behaviour |
| `event_id` | `string` | auto-generated | ❌ | Explicit event ID. Auto-generated as `{resource_name}.{event_name}` if not specified |
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

## See Also

- [Getting Started Tutorial](../tutorials/getting-started.md)
- [What is AshDispatch?](../topics/what-is-ash-dispatch.md)
- [Phoenix Integration](../topics/phoenix-integration.md)
