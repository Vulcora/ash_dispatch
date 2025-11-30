# Getting Started with AshDispatch

This tutorial will walk you through adding event-driven notifications to an Ash resource using **inline events** (defined directly in the `dispatch` DSL).

**Looking for standalone event modules, manual triggers, or preview functionality?** See [Manual Dispatch and Event Modules](./manual-dispatch-and-events.md) for the complete guide on event modules, the two-path pattern, and admin-triggered events.

## Prerequisites

This guide assumes you're familiar with:
- [Ash Framework basics](https://hexdocs.pm/ash/get-started.html)
- Ash resources and actions
- Basic Elixir

## Installation

### 1. Add dependency

```elixir
# mix.exs
def deps do
  [
    {:ash_dispatch, "~> 0.1.0"},
    {:oban, "~> 2.17"},  # Required for async delivery
    {:swoosh, "~> 1.16"} # Required for email transport
  ]
end
```

**Note:** For complete configuration options including standalone event modules, user resources, and custom notification resources, see [Configuration Guide](../topics/configuration.md).

### 2. Configure Oban

AshDispatch uses Oban for asynchronous email delivery. See [Oban Configuration](../topics/oban-configuration.md) for complete setup.

```elixir
# config/config.exs
config :my_app, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.Postgres,
  repo: MyApp.Repo,
  queues: [
    emails: 10  # AshDispatch uses :emails queue
  ]
```

Then add Oban to your supervision tree:

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    MyApp.Repo,
    {Oban, Application.fetch_env!(:my_app, Oban)},
    # ... other children
  ]

  Supervisor.start_link(children, opts: [strategy: :one_for_one])
end
```

### 3. Configure email transport (optional)

AshDispatch uses Swoosh for sending emails. Configure your Swoosh mailer:

```elixir
# config/config.exs
config :my_app, MyApp.Mailer,
  adapter: Swoosh.Adapters.Resend,
  api_key: System.get_env("RESEND_API_KEY")
```

Then configure AshDispatch to use your Swoosh mailer:

```elixir
# config/config.exs
config :ash_dispatch,
  otp_app: :my_app,  # Required for template layouts
  email_backend: AshDispatch.EmailBackend.Swoosh,
  swoosh_mailer: MyApp.Mailer
```

**Available Swoosh adapters:**
- **Resend** - `Resend.Swoosh.Adapter` (recommended)
- **SendGrid** - `Swoosh.Adapters.Sendgrid`
- **Postmark** - `Swoosh.Adapters.Postmark`
- **Mailgun** - `Swoosh.Adapters.Mailgun`
- **SMTP** - `Swoosh.Adapters.SMTP`
- **Local** (dev/test) - `Swoosh.Adapters.Local`

**For tests**, use the test adapter:

```elixir
# config/test.exs
config :my_app, MyApp.Mailer,
  adapter: Swoosh.Adapters.Test

config :ash_dispatch,
  email_backend: AshDispatch.EmailBackend.Swoosh,
  swoosh_mailer: MyApp.Mailer
```

If you don't configure an email backend, AshDispatch will log emails instead of sending them (useful for development).

### 4. Configure URL Builder (optional)

For automatic source URL generation on delivery receipts (linking receipts back to their source resources), configure a URL builder module:

```elixir
# config/config.exs
config :ash_dispatch,
  url_builder: MyApp.UrlBuilder
```

The URL builder should implement two functions:

```elixir
defmodule MyApp.UrlBuilder do
  @moduledoc """
  URL builder for AshDispatch source URLs and labels.

  Builds audience-specific URLs for resources and provides human-readable labels.
  """

  # Load paths at compile time
  @app_paths Application.compile_env(:my_app, :app_paths, %{})

  @doc """
  Returns a human-readable label for a resource type.

  Used by the `source_label` calculation on DeliveryReceipt to provide
  friendly labels for admin UIs.

  ## Examples

      resource_label(:order)  #=> "Order"
      resource_label(:ticket) #=> "Support Ticket"
  """
  def resource_label(:order), do: "Order"
  def resource_label(:ticket), do: "Support Ticket"
  def resource_label(:user), do: "Customer"
  def resource_label(_), do: nil

  @doc """
  Builds a URL for a resource with audience-specific routing.

  ## Parameters
  - `resource_type` - Atom like :order, :ticket (matches event's data_key)
  - `resource` - Map/struct with :id field
  - `opts` - Keyword list with :audience (required), :path_only (optional)

  ## Examples

      build_resource_url(:order, %{id: "abc"}, audience: :user, path_only: true)
      #=> "/orders/abc"

      build_resource_url(:order, %{id: "abc"}, audience: :admin)
      #=> "https://myapp.com/admin/orders/abc"
  """
  def build_resource_url(resource_type, resource, opts) do
    audience = Keyword.fetch!(opts, :audience)
    path_only = Keyword.get(opts, :path_only, false)

    path_template = get_in(@app_paths, [audience, resource_type])

    if is_nil(path_template) do
      raise ArgumentError,
        "No path configured for audience #{inspect(audience)}, " <>
        "resource #{inspect(resource_type)}"
    end

    path = String.replace(path_template, ":id", to_string(resource.id))

    if path_only do
      path
    else
      get_base_url() <> path
    end
  end

  defp get_base_url do
    # Implement based on your endpoint configuration
    "https://myapp.com"
  end
end
```

Configure your path templates:

```elixir
# config/config.exs
config :my_app, :app_paths,
  user: %{
    order: "/orders/:id",
    ticket: "/support/:id"
  },
  admin: %{
    order: "/admin/orders/:id",
    ticket: "/admin/tickets/:id"
  }
```

With this configured, events with `data_key` defined will automatically generate source URLs. The `data_key` (e.g., `:order`) maps directly to the `resource_type` in your path config.

**How it works:**
1. Event defines `data_key: :order`
2. Default `source_url/2` calls `url_builder.build_resource_url(:order, order, audience: channel.audience)`
3. URL builder looks up path template for `:user` or `:admin` audience
4. Returns audience-specific path like `/orders/abc` or `/admin/orders/abc`

Events without `data_key` or with paths not configured will return `nil` for source URL (graceful fallback).

### DeliveryReceipt Calculated Fields

With the URL builder configured, `DeliveryReceipt` provides three calculated fields:

| Field | Description |
|-------|-------------|
| `source_url` | URL using the receipt's audience (`:user` → portal, `:admin` → admin) |
| `source_label` | Human-readable label from `resource_label/1` (e.g., "Order", "Ticket") |
| `admin_url` | Always returns admin URL, regardless of receipt audience |

**Frontend usage example (TypeScript):**

```typescript
// In your admin dashboard, always use adminUrl for links
<Link href={receipt.adminUrl}>
  View {receipt.sourceLabel}
</Link>

// In user portal, use sourceUrl (audience-aware)
<Link href={receipt.sourceUrl}>
  View {receipt.sourceLabel}
</Link>
```

**Why `admin_url`?** When viewing receipts in an admin dashboard, you want admin links even for receipts that were sent to users (which have `audience: :user`). The `admin_url` calculation always uses `audience: :admin` when building the URL.

## Add Your First Event

Let's add notifications to a `Ticket` resource.

### 0. Initial Setup (first time only)

Before creating your first event, set up the directory structure and layouts:

```bash
mix ash_dispatch.setup
```

This creates `priv/ash_dispatch/layouts/` with default email templates. Customize these with your branding. See [Generator Guide](../topics/generator.md) for details.

### 1. Add the extension

```elixir
defmodule MyApp.Tickets.Ticket do
  use Ash.Resource,
    domain: MyApp.Tickets,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshDispatch.Resource]  # Add this!

  # ... existing code ...
end
```

### 2. Define your first event

```elixir
defmodule MyApp.Tickets.Ticket do
  use Ash.Resource,
    domain: MyApp.Tickets,
    extensions: [AshDispatch.Resource]

  actions do
    create :create do
      accept [:title, :description, :user_id]
    end
  end

  # Add dispatch section
  dispatch do
    event :created,
      trigger_on: :create,
      channels: [
        [transport: :in_app, audience: :user]
      ],
      content: [
        notification_title: "Ticket Created",
        notification_message: "Your ticket has been created and assigned ID #{{id}}"
      ],
      metadata: [
        notification_type: :success
      ]
  end
end
```

### 3. Test it out!

```elixir
# Create a ticket
ticket = Ticket
  |> Ash.Changeset.for_create(:create, %{
    title: "Bug report",
    description: "Something is broken",
    user_id: user.id
  })
  |> Ash.create!()

# Check that notification was created
notifications = Notification
  |> Ash.Query.filter(user_id == ^user.id)
  |> Ash.read!()

# You should see:
# [%Notification{
#   title: "Ticket Created",
#   message: "Your ticket has been created and assigned ID #1",
#   notification_type: :success
# }]
```

### 4. Check delivery receipts

Every event creates a `DeliveryReceipt` for tracking:

```elixir
require Ash.Query
import Ash.Expr

# Query receipts for this event
receipts = AshDispatch.Resources.DeliveryReceipt
  |> Ash.Query.filter(expr(event_id == "ticket.created"))
  |> Ash.read!()

# You should see:
# [%AshDispatch.Resources.DeliveryReceipt{
#   id: "a1b2c3d4-...",
#   event_id: "ticket.created",
#   transport: :in_app,
#   audience: :user,
#   recipient: "user-id-...",
#   status: :sent,
#   sent_at: ~U[2025-01-16 10:30:00Z],
#   content: %{
#     title: "Ticket Created",
#     message: "Your ticket has been created and assigned ID #1",
#     notification_type: :success
#   }
# }]

# Query failed deliveries
failed = AshDispatch.Resources.DeliveryReceipt
  |> Ash.Query.filter(expr(status == :failed))
  |> Ash.read!()

# Query by transport
email_receipts = AshDispatch.Resources.DeliveryReceipt
  |> Ash.Query.filter(expr(transport == :email))
  |> Ash.Query.sort(inserted_at: :desc)
  |> Ash.read!()
```

**Receipt Status Lifecycle:**
- `:pending` - Just created
- `:scheduled` - Oban job enqueued (for async transports)
- `:sending` - Currently being delivered
- `:sent` - Successfully delivered ✅
- `:failed` - Delivery failed (will retry)
- `:skipped` - Intentionally skipped (e.g., user opted out)

## Add Email Notifications

Let's send an email when a ticket is resolved.

### 1. Create email templates

```elixir
# lib/my_app/emails/templates/ticket_resolved.html.heex
<h1>Ticket Resolved</h1>

<p>Hi <%= @user_name %>,</p>

<p>Your ticket <strong>#<%= @ticket_id %></strong> has been resolved!</p>

<p><%= @resolution_notes %></p>

<p>
  <a href="<%= @action_url %>">View Ticket</a>
</p>
```

```elixir
# lib/my_app/emails/templates/ticket_resolved.text.eex
Ticket Resolved

Hi <%= @user_name %>,

Your ticket #<%= @ticket_id %> has been resolved!

<%= @resolution_notes %>

View Ticket: <%= @action_url %>
```

### 2. Add the event with callback module

For complex events with templates, use a callback module:

```elixir
dispatch do
  # ... existing :created event ...

  event :resolved,
    trigger_on: :resolve,
    module: MyApp.Events.Tickets.Resolved
end
```

### 3. Create the event module

```elixir
defmodule MyApp.Events.Tickets.Resolved do
  @behaviour AshDispatch.Event

  @impl true
  def channels(_context) do
    [
      [transport: :in_app, audience: :user],
      [transport: :email, audience: :user, delay: 60]
    ]
  end

  @impl true
  def recipients(context, channel) do
    case channel.audience do
      :user -> [context.data.ticket.user]
    end
  end

  @impl true
  def from_email(_context, _channel), do: "support@myapp.com"

  @impl true
  def subject(_context, _channel), do: "Your ticket has been resolved"

  @impl true
  def prepare_template_assigns(context, _channel) do
    %{
      user_name: context.data.ticket.user.name,
      ticket_id: context.data.ticket.id,
      resolution_notes: context.data.ticket.resolution_notes,
      action_url: "#{context.base_url}/tickets/#{context.data.ticket.id}"
    }
  end

  @impl true
  def render_html_email(context, channel) do
    Phoenix.View.render_to_string(
      MyAppWeb.EmailView,
      "ticket_resolved.html",
      prepare_template_assigns(context, channel)
    )
  end

  @impl true
  def render_text_email(context, channel) do
    Phoenix.View.render_to_string(
      MyAppWeb.EmailView,
      "ticket_resolved.text",
      prepare_template_assigns(context, channel)
    )
  end

  @impl true
  def notification_title(_context, _channel), do: "Ticket Resolved"

  @impl true
  def notification_message(context, _channel) do
    "Ticket ##{context.data.ticket.id} has been resolved"
  end
end
```

## Add Multiple Triggers

Events can be triggered by multiple actions:

```elixir
dispatch do
  event :status_changed,
    trigger_on: [:start, :pause, :resume, :resolve, :close],
    channels: [
      [transport: :in_app, audience: :user]
    ],
    content: [
      notification_title: "Ticket Status Updated",
      notification_message: "Ticket #{{id}} status: {{status}}"
    ]
end
```

## Add Admin Notifications

Send notifications to different audiences:

```elixir
dispatch do
  event :created,
    trigger_on: :create,
    channels: [
      # User gets in-app notification
      [transport: :in_app, audience: :user],

      # Admins get email immediately
      [transport: :email, audience: :admin],

      # User gets email after 5 minutes (if not read)
      [transport: :email, audience: :user, delay: 300, policy: :skip_if_read]
    ],
    content: [
      subject: "New Ticket: {{title}}",
      notification_title: "New Ticket",
      notification_message: "{{user_name}} created ticket #{{id}}"
    ]
end
```

## Preload Relationships

If your event needs related data, preload it:

```elixir
dispatch do
  event :created,
    trigger_on: :create,
    load: [:user, :assignee],  # Preload these relationships
    channels: [
      [transport: :email, audience: :user]
    ],
    content: [
      subject: "Ticket assigned to {{assignee_name}}"
    ]
end
```

## Variable Interpolation

AshDispatch automatically replaces `{{variable}}` placeholders with actual values from your resource data.

### Basic Usage

Use double curly braces in any inline content field:

```elixir
content: [
  subject: "Ticket #{{id}} - {{status}}",
  notification_title: "Hello {{user_name}}!",
  notification_message: "Created at {{inserted_at}}",
  action_url: "/tickets/{{id}}"
]
```

### Variable Sources

Variables can come from three sources:

**1. Direct Attributes** - Fields on the resource itself:
```elixir
# In Ticket resource with fields: id, status, title, priority
content: [
  notification_message: "Ticket #{{id}}: {{title}} (Priority: {{priority}})"
]
# → "Ticket #123: Bug report (Priority: high)"
```

**2. Nested Attributes** - Preloaded relationships using dot notation:
```elixir
dispatch do
  event :assigned,
    trigger_on: :assign,
    load: [:user, :assignee],  # Preload these first!
    content: [
      notification_message: "{{user.name}} assigned ticket to {{assignee.email}}"
    ]
end
# → "Alice assigned ticket to bob@example.com"
```

**3. Flattened Keys** - Alternative syntax for nested attributes:
```elixir
# These are equivalent:
notification_message: "Hello {{user.name}}"
notification_message: "Hello {{user_name}}"  # Underscore becomes dot

# Useful for deeply nested data:
notification_message: "Org: {{organization.billing_contact.email}}"
notification_message: "Org: {{organization_billing_contact_email}}"
```

### Type Conversion

Values are automatically converted to strings:

```elixir
# Atoms
{{status}} where status = :active → "active"

# Numbers
{{id}} where id = 123 → "123"
{{price}} where price = 99.99 → "99.99"

# Booleans
{{active}} where active = true → "true"

# Dates & Times
{{inserted_at}} where inserted_at = ~U[2025-01-16 10:30:00Z]
→ "2025-01-16 10:30:00Z"

# Nil values
{{missing}} where missing = nil → "" (empty string)
```

### Safety Features

**Missing Variables** - No errors, just empty strings:
```elixir
notification_message: "Value: {{nonexistent_field}}"
# → "Value: " (empty)
```

**Nil Handling** - Gracefully handled:
```elixir
notification_message: "User: {{user.name}}"
# If user is nil → "User: "
# If user.name is nil → "User: "
```

**Missing Relationships** - Must be preloaded:
```elixir
# ❌ Will return empty if not preloaded:
notification_message: "{{user.name}}"

# ✅ Preload first:
dispatch do
  event :created,
    trigger_on: :create,
    load: [:user],  # Preload here!
    content: [
      notification_message: "{{user.name}} created a ticket"
    ]
end
```

### Common Patterns

**Dynamic URLs:**
```elixir
content: [
  action_url: "/tickets/{{id}}/comments/{{comment_id}}"
]
```

**Conditional-like Content:**
```elixir
# You can't use real conditionals, but you can use multiple events:
event :ticket_urgent,
  trigger_on: :create,
  channels: [[transport: :email, audience: :admin]],
  content: [
    subject: "🚨 URGENT: Ticket #{{id}} - {{title}}"
  ]

event :ticket_normal,
  trigger_on: :create,
  channels: [[transport: :in_app, audience: :user]],
  content: [
    subject: "Ticket #{{id}} - {{title}}"
  ]
```

**Multi-level Nesting:**
```elixir
dispatch do
  event :order_shipped,
    trigger_on: :ship,
    load: [:user, :shipping_address, :items],
    content: [
      notification_message: """
      Hi {{user.name}},

      Your order #{{id}} has shipped to:
      {{shipping_address.street}}
      {{shipping_address.city}}, {{shipping_address.state}}

      Items: {{items}} (note: lists don't interpolate well)
      """
    ]
end
```

### Troubleshooting

**Variable shows as `{{name}}` instead of value:**
- ✅ Check spelling (variables are case-sensitive)
- ✅ Ensure field exists on resource
- ✅ For nested fields, verify relationship is in `load: [...]`
- ✅ Check that relationship loaded successfully (not `%Ecto.Association.NotLoaded{}`)

**Variable shows as empty string:**
- This means the value is `nil` or the field doesn't exist
- Add `load: [:relationship]` if accessing nested data
- Verify the field name matches exactly (case-sensitive)

## User Preferences

Let users control which notifications they receive by implementing preference checking.

### 1. Configure Your Preference Checker

```elixir
# config/config.exs
config :ash_dispatch,
  user_preference: MyApp.NotificationPreferences
```

### 2. Implement the Behaviour

```elixir
defmodule MyApp.NotificationPreferences do
  @behaviour AshDispatch.UserPreference

  @impl true
  def user_allows?(user_id, _event_id, transport, opts) do
    category = opts[:category]

    case Ash.get(UserPreference, user_id) do
      {:ok, prefs} ->
        # Check if user disabled this category or transport
        category not in prefs.disabled_categories and
        transport not in prefs.disabled_transports

      _ ->
        true  # Allow if no preferences found
    end
  end
end
```

### 3. Add Categories to Events

```elixir
dispatch do
  event :promotional_offer,
    trigger_on: :create,
    channels: [[transport: :email, audience: :user]],
    metadata: [
      category: :marketing  # Users can opt out of this
    ]
end
```

### How Preference Checking Works

1. **Receipt Created** - Delivery receipt created with status `:pending`
2. **Preference Check** - Transport calls `UserPreference.allows?/3`
3. **If Opted Out** - Receipt marked `:skipped` with error `"user_opted_out"`
4. **If Allowed** - Delivery proceeds normally

**Important:** Receipts are always created for audit purposes, even if skipped.

### Preference Granularity

Users can control at three levels:

**By Category:**
```elixir
# User opts out of all marketing
disabled_categories: [:marketing, :promotional]
```

**By Transport:**
```elixir
# User opts out of emails only
disabled_transports: [:email]  # Still gets :in_app
```

**Combined:**
```elixir
# User opts out of marketing emails but allows marketing in-app
def user_allows?(user_id, _event_id, transport, opts) do
  category = opts[:category]

  # Check category + transport combinations
  {category, transport} not in get_disabled_combinations(user_id)
end
```

### Which Events Are Checked?

**✅ Preference checking applies to:**
- Events with `audience: :user`
- User-configurable events

**❌ Preferences are bypassed for:**
- Events with `audience: :admin`
- Events with `audience: :team`
- Events with `audience: :system`
- Critical system notifications

### Testing Preference Checking

```elixir
test "user who opted out gets notification skipped" do
  user = create_opted_out_user()

  {:ok, order} = create_order(%{user_id: user.id})

  # Verify receipt was skipped
  receipts = DeliveryReceipt
    |> Ash.Query.filter(event_id == "order.created")
    |> Ash.read!()

  assert hd(receipts).status == :skipped
  assert hd(receipts).error_message == "user_opted_out"
end
```

See [User Preferences](../topics/user-preferences.md) for complete documentation including UI integration, caching, and advanced patterns.

## Testing Events

### Test that events are defined

```elixir
defmodule MyApp.TicketTest do
  use ExUnit.Case

  alias MyApp.Tickets.Ticket

  test "has dispatch events defined" do
    dsl_state = Ticket.spark_dsl_config()
    events = Spark.Dsl.Transformer.get_entities(dsl_state, [:dispatch])

    assert length(events) == 2
    assert Enum.find(events, &(&1.name == :created))
    assert Enum.find(events, &(&1.name == :resolved))
  end
end
```

### Test event dispatch

```elixir
test "creating ticket dispatches event" do
  ticket = create_ticket()

  # Check that notification was created
  notifications = Notification
    |> Ash.Query.filter(user_id == ^ticket.user_id)
    |> Ash.read!()

  assert [notification] = notifications
  assert notification.title == "Ticket Created"
end
```

### Test email content with factories

```elixir
test "resolved email renders correctly" do
  # Use factory to build test data (no database!)
  ticket = build(:ticket, %{
    id: 123,
    user: build(:user, %{name: "Alice"}),
    resolution_notes: "Fixed the bug"
  })

  context = %AshDispatch.Context{
    event_id: "ticket.resolved",
    data: %{ticket: ticket},
    base_url: "https://app.example.com"
  }

  channel = %AshDispatch.Channel{transport: :email, audience: :user}

  html = MyApp.Events.Tickets.Resolved.render_html_email(context, channel)

  assert html =~ "Hi Alice"
  assert html =~ "Ticket #123"
  assert html =~ "Fixed the bug"
end
```

## Add Real-Time Counters

Counters broadcast live updates to frontend UIs. Add them to your resource:

```elixir
defmodule MyApp.Tickets.Ticket do
  use Ash.Resource,
    extensions: [AshDispatch.Resource]

  # ... existing dispatch events ...

  counters do
    # User sees their open tickets
    counter :open_tickets,
      trigger_on: [:create, :resolve, :close],
      query_filter: [status: :open],
      audience: :user,
      group: :tickets,
      invalidates: ["tickets"]

    # Admin sees ALL open tickets (system-wide)
    counter :admin_open_tickets,
      trigger_on: [:create, :resolve, :close],
      query_filter: [status: :open],
      audience: :admin,
      authorize?: false,  # Bypass policies - count ALL records
      invalidates: ["tickets"]
  end
end
```

### Counter Options Explained

| Option | Purpose |
|--------|---------|
| `trigger_on` | Actions that trigger broadcast |
| `query_filter` | Static filter for counting (e.g., `[status: :open]`) |
| `audience` | WHO receives the broadcast (`:user`, `:admin`, custom) |
| `authorize?` | `false` = bypass policies (admin dashboards) |
| `scope` | Ash expression for custom filtering (see below) |
| `invalidates` | Frontend query keys to invalidate |

### Advanced: Scope Expressions

For complex scoping beyond simple user_id relationships:

```elixir
# Regional admin sees only their region
counter :regional_open_tickets,
  trigger_on: [:create, :resolve],
  query_filter: [status: :open],
  audience: :admin,
  scope: expr(region == ^actor(:region)),
  invalidates: ["tickets"]

# Admin sees their assigned tickets
counter :my_assigned_tickets,
  trigger_on: [:create, :resolve],
  query_filter: [status: :open],
  audience: :admin,
  scope: expr(assigned_to_id == ^actor(:id)),
  invalidates: ["tickets"]
```

See [Counter Broadcasting](../topics/counter-broadcasting.md) for complete documentation.

## Next Steps

**Recommended next:** [App Integration](../topics/app-integration.md) - Set up custom resources, database, and RPC

Then explore:
- [Phoenix Integration](../topics/phoenix-integration.md) - Real-time channels and frontend
- [Counter Broadcasting](../topics/counter-broadcasting.md) - Complete counter documentation
- [User Preferences](../topics/user-preferences.md) - Let users control notifications
- [DSL Reference](../dsls/DSL-AshDispatch-Resource.md) - Complete DSL documentation

## Common Patterns

### Delayed Email After In-App

Send in-app notification immediately, email if not read:

```elixir
channels: [
  [transport: :in_app, audience: :user],
  [transport: :email, audience: :user, delay: 300, policy: :skip_if_read]
]
```

### Admin Alerts

```elixir
channels: [
  [transport: :email, audience: :admin],
  [transport: :discord, audience: :team, webhook_url: "https://..."]
]
```

### Progressive Reminders

```elixir
# Define multiple events with increasing delays
event :payment_due_soon,
  trigger_on: :create,
  channels: [[transport: :email, audience: :user, delay: 86400]]  # 1 day

event :payment_overdue,
  trigger_on: :create,
  channels: [[transport: :email, audience: :user, delay: 259200]]  # 3 days
```

## Troubleshooting

### Events not firing

1. Check that extension is added: `extensions: [AshDispatch.Resource]`
2. Verify action name matches `trigger_on`
3. Check Oban is running: `Oban.check_queue(queue: :ash_dispatch_email)`

### Emails not sending

1. Verify Swoosh is configured
2. Check Oban job logs
3. Look for delivery receipts with `:failed` status

### Variables not interpolating

1. Ensure variable exists on the resource
2. Preload relationships with `load: [...]`
3. Check spelling (case-sensitive!)

## Help & Support

- [GitHub Issues](https://github.com/magasin/ash_dispatch/issues)
- [Ash Community](https://ash-hq.org)
- [Documentation](../README.md)
