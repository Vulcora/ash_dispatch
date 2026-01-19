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

### Event Modules (Auto-Discovered)

Event modules are **automatically discovered** from your Ash domains - no manual configuration needed!

AshDispatch scans all resources with `AshDispatch.Resource` extension and finds:
1. Events with explicit `module:` option in DSL
2. Auto-generated event modules following the naming convention

```elixir
# OLD - No longer needed!
# config :ash_dispatch, :event_modules, [...]

# NEW - Just configure your otp_app and domains
config :ash_dispatch, :otp_app, :my_app

config :my_app, :ash_domains, [
  MyApp.Orders,
  MyApp.Tickets
]
```

The `AshDispatch.EventRegistry` module handles discovery:
- `EventRegistry.get_event_modules()` - Returns `[{event_id, module}, ...]`
- `EventRegistry.find_event("order.created")` - Find specific event
- `EventRegistry.find_module("order.created")` - Find event module

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

### Localization

Configure default locale for template resolution:

```elixir
config :ash_dispatch,
  default_locale: "sv"  # Default when no locale found (defaults to "en")
```

**Why needed:**
- Sets the fallback language for email and SMS templates
- Used when no locale is configured on channel, event, or resource
- Templates fall back to non-localized versions if locale-specific not found

**Default:** `"en"`

See [Localization](localization.md) for the complete i18n guide including:
- Resource-level locale configuration
- Dynamic locale from record fields
- Template fallback chain
- Multi-language templates

### Phoenix Channel Topic

Configure the channel topic prefix for real-time notifications:

```elixir
config :ash_dispatch,
  channel_topic: "inbox"  # Creates topics like "inbox:user_id"
```

**Default:** `"user"` (creates topics like `"user:user_id"`)

**Why needed:**
- Must match your Phoenix channel topic structure
- Used for broadcasting notifications and counter updates

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

### Recipient Resolver (Recommended)

Configure a declarative recipient resolver module for audience resolution:

```elixir
config :ash_dispatch,
  recipient_resolver: MyApp.RecipientResolver
```

The `RecipientResolver` module uses a DSL to define how recipients are resolved:

```elixir
defmodule MyApp.RecipientResolver do
  use AshDispatch.RecipientResolver,
    user_resource: MyApp.Accounts.User

  audiences do
    audience :user, from_context: :user
    audience :admins, query: [role: :admin, is_active: true]
    audience :owner, resolve: :resolve_owner
    audience :stakeholders, combine: [:owner, :team]
  end

  @impl true
  def to_recipient(%MyApp.Accounts.User{} = user) do
    %{id: user.id, email: to_string(user.email), display_name: user.full_name}
  end

  def resolve_owner(resource, context) do
    # Custom resolution logic
  end
end
```

**Resolution Strategies:**

| Strategy | Example | Description |
|----------|---------|-------------|
| `from_context` | `from_context: :user` | Extract from context.data |
| `query` | `query: [role: :admin]` | Query user_resource with Ash filter |
| `path` | `path: [:team, :users]` | Follow relationship path on resource |
| `combine` | `combine: [:owner, :team]` | Union of other audiences |
| `resolve` | `resolve: :resolve_owner` | Custom resolver function |

See [Recipient Resolution](recipient-resolution.md) for the complete guide.

### Audiences (Legacy Configuration)

> **Note:** The `audiences` config is legacy. Prefer using `recipient_resolver` above for new projects.

Configure how recipients are resolved for each audience type:

```elixir
config :ash_dispatch,
  audiences: [
    # Bare atom = relationship-based (extract from record)
    :user,      # Extract from :user relationship
    :creator,   # Extract from :creator relationship
    :partner,   # Extract from :partner relationship

    # Tuple = filter-based (query all matching users)
    {:admin, [:user, {:admin, true}]},
    {:super_admin, [:user, {:super_admin, true}]},
    {:support, [:user, {:role, :support}]}
  ]
```

**Two configuration patterns:**

| Pattern | Format | Behavior |
|---------|--------|----------|
| Relationship-based | `:user` | Extract from record's relationship |
| Filter-based | `{:admin, [...]}` | Query all users matching filter |

**Default:** `[]` (assumes relationship-based for unknown audiences)

See [Counter Broadcasting](counter-broadcasting.md) and [Recipient Resolution](recipient-resolution.md) for details.

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

### Send Now Authorizer

Configure authorization for the `send_now` action on delivery receipts. This action allows manually triggering email delivery for scheduled receipts from an admin UI.

```elixir
config :ash_dispatch,
  send_now_authorizer: MyApp.Deliveries.SendNowAuthorizer
```

**Default:** `nil` (any authenticated actor can use `send_now`)

**Why needed:**
- Restrict manual email triggering to specific user roles (e.g., super admins only)
- Prevent accidental mass email sends by regular admins
- Audit control over who can bypass normal scheduling

**Implementing an authorizer:**

Your authorizer module must implement an `authorize/1` function that receives the actor and returns `:ok` or `{:error, message}`:

```elixir
defmodule MyApp.Deliveries.SendNowAuthorizer do
  @moduledoc """
  Authorizes send_now action for delivery receipts.
  Only super admins can manually trigger email sending.
  """

  @doc """
  Check if actor is authorized to use send_now.

  Returns:
  - `:ok` if authorized
  - `{:error, message}` if not authorized
  """
  def authorize(%{super_admin: true}), do: :ok
  def authorize(_actor), do: {:error, "Only super admins can manually trigger email sending"}
end
```

**Behavior:**
- When `nil`: Any authenticated actor can use `send_now`
- When configured: The authorizer is called with the actor
- System calls (no actor): Always allowed regardless of authorizer

**Important:** The actor must be passed to `Ash.Changeset.for_update/3` for the authorizer to receive it:

```elixir
# Correct - actor passed to for_update
receipt
|> Ash.Changeset.for_update(:send_now, %{}, actor: current_user)
|> Ash.update(authorize?: true)

# Incorrect - actor won't reach the validation
receipt
|> Ash.Changeset.for_update(:send_now, %{})
|> Ash.update(actor: current_user, authorize?: true)
```

### Audience Resolution

Configure how recipients are resolved for each audience using `recipient_filters`:

```elixir
config :ash_dispatch,
  recipient_filters: [
    audiences: [
      # Bare atom: extract from relationship with same name
      :user,
      :creator,

      # Filter-based: query users matching filter
      admin: [:user, admin: true],
      partner: [:user, role: :partner],

      # Relationship chain: follow multiple relationships
      seller: [:user, :associated_seller]
    ]
  ]
```

This replaces the need for custom resolver modules. See [Recipient Resolution](recipient-resolution.md)
for all 6 supported audience formats and advanced examples.

## Complete Example

Here's a complete configuration with all features enabled:

```elixir
# config/config.exs
config :ash_dispatch,
  # Required: Your app's OTP name (for event auto-discovery)
  otp_app: :my_app,

  # Counter broadcasting (real-time updates)
  counter_broadcast_fn: {MyAppWeb.UserChannel, :broadcast_counter},
  domains: [MyApp.Orders, MyApp.Tickets, MyApp.Catalog, MyApp.Accounts],
  user_module: MyApp.Accounts.User,

  # Audience configuration (unified format)
  audiences: [
    # Relationship-based (extract from record)
    :user,
    :partner,

    # Filter-based (query all matching users)
    {:admin, [:user, {:admin, true}]},
    {:super_admin, [:user, {:super_admin, true}]}
  ],

  # Event modules are AUTO-DISCOVERED from domains - no manual config needed!
  # The EventRegistry scans resources with AshDispatch.Resource extension

  # User/admin resolution
  user_resource: MyApp.Accounts.User,
  user_domain: MyApp.Accounts,

  # Custom resources
  notification_resource: MyApp.Notifications.Notification,
  delivery_receipt_resource: MyApp.Deliveries.DeliveryReceipt,

  # Action authorization (restrict send_now to super admins)
  send_now_authorizer: MyApp.Deliveries.SendNowAuthorizer,

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
- [Delivery Receipts](delivery-receipts.md) - Receipt management and admin actions
- [User Preferences](user-preferences.md) - Implement preference checking
- [Oban Configuration](oban-configuration.md) - Configure job queue
