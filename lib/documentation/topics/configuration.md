# Configuration

AshDispatch is designed to be flexible and configurable. This guide covers all available configuration options and when to use them.

## Required Configuration

### Counter Broadcasting (for real-time counters)

Configure the function to call when broadcasting counter updates to Phoenix Channels:

```elixir
# config/config.exs
config :ash_dispatch,
  counter_broadcast_fn: {MyAppWeb.UserChannel, :broadcast_counter}
```

**Options:**

```elixir
# MFA tuple (recommended - easier to test)
counter_broadcast_fn: {MyAppWeb.UserChannel, :broadcast_counter}

# Or function capture
counter_broadcast_fn: &MyAppWeb.UserChannel.broadcast_counter/4
```

**Your broadcast function should accept:**
- `user_id` (string) - The user to broadcast to
- `counter_name` (atom) - The counter name (e.g., `:pending_orders`)
- `value` (integer) - The current count
- `opts` (keyword list) - Options including `:metadata` with `invalidate_queries`

**Example implementation:**

```elixir
defmodule MyAppWeb.UserChannel do
  def broadcast_counter(user_id, counter_name, value, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    MyAppWeb.Endpoint.broadcast("user:#{user_id}", "counter_updated", %{
      counter: counter_name,
      value: value,
      metadata: metadata
    })
  end
end
```

See [Phoenix Channel Integration](phoenix-integration.md) for complete setup guide.

### Email Backend (if using email transport)

Configure Swoosh for email delivery:

```elixir
# config/config.exs
config :ash_dispatch,
  email_backend: AshDispatch.EmailBackend.Swoosh,
  swoosh_mailer: MyApp.Mailer

config :my_app, MyApp.Mailer,
  adapter: Swoosh.Adapters.Resend,
  api_key: System.get_env("RESEND_API_KEY")
```

### Oban (for async delivery)

Configure Oban for asynchronous email delivery:

```elixir
config :my_app, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.Postgres,
  repo: MyApp.Repo,
  queues: [
    emails: 10  # AshDispatch uses :emails queue
  ]
```

See [Oban Configuration](oban-configuration.md) for complete setup.

## Standalone Event Module Configuration

If you're using standalone event modules (with `AshDispatch.Event` behaviour) instead of the DSL-based approach, you need to configure these options:

### Event Modules Registry

Register all your event modules so AshDispatch can find them:

```elixir
config :ash_dispatch, :event_modules, [
  # Format: {event_id, module}
  {"orders.created", MyApp.Orders.Events.Created.Event},
  {"orders.shipped", MyApp.Orders.Events.Shipped.Event},
  {"tickets.resolved", MyApp.Tickets.Events.Resolved.Event}
]
```

This configuration is used by:
- `AshDispatch.Changes.DispatchEvent` to find event modules
- `AshDispatch.Dispatcher.dispatch/2` for manual event triggering
- Manual trigger UI to list available events

### User Resource

Specify your application's User resource for recipient resolution:

```elixir
config :ash_dispatch,
  user_resource: MyApp.Accounts.User,
  user_domain: MyApp.Accounts
```

**Why needed:**
- Resolves `:user` audience to actual user records
- Loads user relationships for template rendering
- Used by recipient resolution when dispatching events

**Default:** `nil` (must be configured for `:user` audience)

### Preference Provider

Implement user notification preferences checking:

```elixir
config :ash_dispatch,
  preference_provider: MyApp.NotificationPreferences
```

Your preference provider must implement `AshDispatch.PreferenceProvider` behaviour:

```elixir
defmodule MyApp.NotificationPreferences do
  @behaviour AshDispatch.PreferenceProvider

  @impl true
  def allows_notification?(user_id, event_id, transport, opts) do
    # Check if user allows this notification
    # Return true/false
  end
end
```

**Why needed:**
- Respects user opt-out preferences
- Required if you want user-configurable notifications
- Called before every delivery to `:user` audience

**Default:** `nil` (all notifications allowed)

See [User Preferences](user-preferences.md) for implementation guide.

### Recipient Fields (Recipient Field Extraction)

Configure how recipient information is extracted for each transport:

```elixir
config :ash_dispatch,
  recipient_fields: [
    email: [
      identifier: :email,
      name: [:contact_person, :display_name, :name]
    ],
    in_app: [
      identifier: :id,
      name: [:contact_person, :display_name, :name]
    ]
  ]
```

**Why needed:**
- Different transports need different recipient data (email address vs phone number vs user ID)
- Supports fallback chains for name fields
- Allows per-audience overrides for special cases

**Transport-first structure:** Each transport defines its own `identifier` (where to send) and `name` (who to display).

**Fallback chains:** For name fields, specify a list of fields to try in order:
```elixir
name: [:display_name, :name, :contact_person]  # tries each until one has a value
```

**Per-audience overrides:**
```elixir
recipient_fields: [
  email: [identifier: :email, name: :contact_person],

  audiences: [
    admin: [email: [name: :full_name]],  # admins show full name
    customer: [email: [identifier: :contact_email]]  # customers use different email
  ]
]
```

See [Recipient Field Extraction](recipient-extractor.md) for complete guide and advanced formats.

### Notification Resource

Override the default notification resource with your own (for in-app notifications):

```elixir
config :ash_dispatch,
  notification_resource: MyApp.Notifications.Notification
```

**Why needed:**
- Use your own Notification resource with custom fields
- Enable PubSub broadcasting for real-time updates
- Store notifications in Postgres instead of ETS
- Add custom policies and validations

**Default:** `AshDispatch.Resources.Notification` (ETS-based, no broadcasting)

**Requirements for custom notification resource:**
- Must accept these attributes in `:create` action:
  - `:user_id` (uuid)
  - `:title` (string)
  - `:message` (string)
  - `:action_url` (string, optional)
  - `:event_id` (string, optional)
  - `:type` or `:notification_type` (atom: :info, :success, :warning, :error)

**Example custom notification resource:**

```elixir
defmodule MyApp.Notifications.Notification do
  use Ash.Resource,
    domain: MyApp.Notifications,
    data_layer: AshPostgres.DataLayer,
    notifiers: [Ash.Notifier.PubSub]

  postgres do
    table "notifications"
    repo MyApp.Repo
  end

  # Enable real-time broadcasting
  pub_sub do
    module MyAppWeb.Endpoint
    prefix "notifications"

    publish_all :create, ["user", :user_id]
    publish_all :update, ["user", :user_id]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [
        :user_id,
        :type,           # or :notification_type
        :title,
        :message,
        :action_url,
        :event_id
      ]
    end

    update :mark_as_read do
      accept [:read, :read_at]
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :user_id, :uuid do
      allow_nil? false
    end

    attribute :type, :atom do
      allow_nil? false
      constraints one_of: [:info, :success, :warning, :error]
    end

    attribute :title, :string do
      allow_nil? false
    end

    attribute :message, :string do
      allow_nil? false
    end

    attribute :action_url, :string

    attribute :event_id, :string

    attribute :read, :boolean do
      default false
    end

    attribute :read_at, :utc_datetime_usec

    timestamps()
  end

  relationships do
    belongs_to :user, MyApp.Accounts.User do
      allow_nil? false
    end
  end
end
```

## Optional Configuration

### Ash Domains (for counter auto-discovery)

Specify which Ash domains to scan for counter definitions:

```elixir
config :ash_dispatch,
  domains: [MyApp.Orders, MyApp.Tickets, MyApp.Catalog, MyApp.Accounts]
```

**Why needed:**
- CounterLoader scans these domains to discover counter definitions
- Required if you're using the counter broadcasting feature
- Counters defined in resources outside these domains won't be loaded

**Default:** `[]` (no domains scanned)

### Audience Filters (for counter routing)

Define how to identify users for different counter audiences:

```elixir
config :ash_dispatch,
  recipient_filters: [
    audiences: [
      admin: [admin: true],
      partner: [role: :partner, active: true],
      support: [role: :support],
      user: []  # All authenticated users
    ]
  ]
```

**Why needed:**
- Determines which users receive which counter updates
- Used by CounterLoader to filter counters by user's audiences
- Required for `:admin`, `:partner`, and other custom audiences

**Default:** `[]` (no audience filters)

**Example queries:**
- `admin: [admin: true]` → Queries `User |> filter(admin == true)`
- `partner: [role: :partner]` → Queries `User |> filter(role == :partner)`
- `user: []` → Matches all users (no filter)

See [Counter Broadcasting](counter-broadcasting.md) for audience details.

### Base URL

Set the base URL for generating links in notifications:

```elixir
config :ash_dispatch,
  base_url: "https://app.example.com"
```

**Default:** `"http://localhost:4000"`

**Used by:**
- Link generation in emails
- Action URLs in notifications
- Available in context as `context.base_url`

### Email From Address

Default sender email address:

```elixir
config :ash_dispatch,
  default_from_email: {"My App Support", "support@example.com"}
```

**Default:** `{"AshDispatch", "noreply@example.com"}`

**Note:** Event modules can override this per-event via `from/2` callback.

### Delivery Receipt Resource

Override the default delivery receipt resource:

```elixir
config :ash_dispatch,
  delivery_receipt_resource: MyApp.Deliveries.DeliveryReceipt
```

**Default:** `AshDispatch.Resources.DeliveryReceipt`

**Why override:**
- Add custom fields for your use case
- Integrate with existing audit/logging systems
- Custom policies or validations

### Admin Resolver

Configure how to resolve admin users for `:admin` audience:

```elixir
config :ash_dispatch,
  admin_resolver: MyApp.AdminResolver
```

Your admin resolver must implement:

```elixir
defmodule MyApp.AdminResolver do
  def resolve_admins(context, opts \\ []) do
    # Return list of admin user structs
    # opts may contain filters like [role: :support]
  end
end
```

**Default:** Uses `user_resource` with `filter: [admin: true]`

## Complete Example

Here's a complete configuration with all features enabled:

```elixir
# config/config.exs
config :ash_dispatch,
  # Counter broadcasting (real-time updates)
  counter_broadcast_fn: {MyAppWeb.UserChannel, :broadcast_counter},
  domains: [MyApp.Orders, MyApp.Tickets, MyApp.Catalog, MyApp.Accounts],
  user_module: MyApp.Accounts.User,
  recipient_filters: [
    audiences: [
      admin: [admin: true],
      partner: [role: :partner],
      user: []
    ]
  ],

  # Standalone event modules (if using)
  event_modules: [
    {"orders.created", MyApp.Orders.Events.Created.Event},
    {"orders.shipped", MyApp.Orders.Events.Shipped.Event},
    {"tickets.created", MyApp.Tickets.Events.Created.Event},
    {"tickets.resolved", MyApp.Tickets.Events.Resolved.Event}
  ],

  # User/admin resolution
  user_resource: MyApp.Accounts.User,
  user_domain: MyApp.Accounts,

  # Custom resources
  notification_resource: MyApp.Notifications.Notification,
  delivery_receipt_resource: MyApp.Deliveries.DeliveryReceipt,

  # User preferences
  preference_provider: MyApp.NotificationPreferences,

  # Email configuration
  email_backend: AshDispatch.EmailBackend.Swoosh,
  swoosh_mailer: MyApp.Mailer,
  default_from_email: {"My App", "noreply@myapp.com"},

  # Base URL
  base_url: "https://app.myapp.com"

# Swoosh configuration
config :my_app, MyApp.Mailer,
  adapter: Swoosh.Adapters.Resend,
  api_key: System.get_env("RESEND_API_KEY")

# Oban configuration
config :my_app, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.Postgres,
  repo: MyApp.Repo,
  queues: [emails: 10]
```

## Environment-Specific Configuration

### Development

```elixir
# config/dev.exs
config :ash_dispatch,
  base_url: "http://localhost:4000"

# Use local email adapter
config :my_app, MyApp.Mailer,
  adapter: Swoosh.Adapters.Local
```

### Test

```elixir
# config/test.exs
config :ash_dispatch,
  base_url: "http://localhost:4002"

# Use test adapter
config :my_app, MyApp.Mailer,
  adapter: Swoosh.Adapters.Test
```

### Production

```elixir
# config/runtime.exs
config :ash_dispatch,
  base_url: System.get_env("APP_URL") || "https://app.example.com"

config :my_app, MyApp.Mailer,
  adapter: Swoosh.Adapters.Resend,
  api_key: System.get_env("RESEND_API_KEY")
```

## Configuration Validation

AshDispatch validates configuration at compile time and runtime. You'll see warnings if:

- Email backend configured but Swoosh not available
- User resource configured but not found
- Notification resource missing required attributes

## Next Steps

- [Getting Started](../tutorials/getting-started.md) - Basic setup
- [User Preferences](user-preferences.md) - Implement preference checking
- [Oban Configuration](oban-configuration.md) - Configure job queue
