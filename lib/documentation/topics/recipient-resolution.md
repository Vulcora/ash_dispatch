# Recipient Resolution

AshDispatch automatically resolves recipients using **DSL-based configuration** - define once in config, works everywhere!

## Quick Start (Zero Configuration!)

### 1. Configure Your App Structure

Tell AshDispatch about your User module and audience filters:

```elixir
# config/config.exs
config :ash_dispatch,
  user_module: MyApp.Accounts.User,
  recipient_filters: [
    audiences: [
      # Bare atom = extract from relationship with same name
      :user,                      # Extract from :user relationship
      :creator,                   # Extract from :creator relationship

      # Relationship path + filter: query users matching filter
      admin: [:user, admin: true],
      partner: [:user, role: :partner],

      # Relationship chain: follow multiple relationships
      sellers: [:user, :associated_seller],

      # Template filters with dynamic values
      regional_admin: [:user, admin: true, region: {:resource, [:user, :region]}]
    ]
  ]
```

### 2. That's It!

AshDispatch now automatically:
- ✅ Resolves recipients based on DSL-configured filters
- ✅ Queries admins/partners/custom audiences using your filters
- ✅ Extracts emails (even CiString types!)
- ✅ Handles user preferences automatically
- ✅ Works with ANY Ash resource structure
- ✅ Supports custom audiences with zero code changes

## How It Works

### Auto-Inference Pattern

AshDispatch supports **multiple audience configuration formats** with intelligent auto-inference:

#### Format 1: Bare Atom (Auto-Infer)

The simplest pattern - just list the audience, and AshDispatch extracts from the relationship with the same name:

```elixir
config :ash_dispatch,
  recipient_filters: [
    audiences: [
      :user,      # Extract from :user relationship
      :creator,   # Extract from :creator relationship
      :assignee   # Extract from :assignee relationship
    ]
  ]

# For an Order with belongs_to :user relationship:
%{order: %Order{user: %User{}}}

# AshDispatch automatically:
# 1. Sees :user in bare atom list
# 2. Looks for :user relationship on Order
# 3. Extracts the user
```

**When to use:** Relationship name matches audience name (most common case!)

---

#### Format 2: Relationship Path + Filter

Query users matching a filter via a specified relationship:

```elixir
config :ash_dispatch,
  recipient_filters: [
    audiences: [
      admin: [:user, admin: true],
      partner: [:user, role: :partner, active: true],
      support: [:user, role: :support]
    ]
  ]

# AshDispatch queries:
MyApp.Accounts.User
|> Ash.Query.filter(admin == true)
|> Ash.read!()
```

**When to use:** Notifying groups of users (admins, partners, etc.)

---

#### Format 3: Relationship Chain

Follow multiple relationships to reach recipients:

```elixir
config :ash_dispatch,
  recipient_filters: [
    audiences: [
      # Follow user.associated_seller
      sellers: [:user, :associated_seller],

      # Follow user.team.lead
      team_lead: [:user, :team, :lead]
    ]
  ]

# For an Order with user.associated_seller:
%{order: %Order{user: %User{associated_seller: %Seller{}}}}

# AshDispatch:
# 1. Extracts user from order
# 2. Follows associated_seller relationship
# 3. Returns the seller as recipient
```

**When to use:** Recipients accessed via relationship chains

---

#### Format 4: Template Filters (Dynamic Values)

Filters with values extracted from event context:

```elixir
config :ash_dispatch,
  recipient_filters: [
    audiences: [
      # Admins in the same region as the event's user
      regional_admin: [:user, admin: true, region: {:resource, [:user, :region]}]
    ]
  ]

# For event with user in region "EU":
%{order: %Order{user: %User{region: "EU"}}}

# AshDispatch resolves:
# 1. Extracts [:user, :region] from context → "EU"
# 2. Queries: User |> filter(admin == true and region == "EU")
# 3. Returns all EU admins
```

**When to use:** Dynamic filters based on event context (regional routing, team assignment)

---

#### Format 5: Function/MFA (Full Dynamic Logic)

Call a function for complex recipient resolution:

```elixir
config :ash_dispatch,
  recipient_filters: [
    audiences: [
      on_duty_admin: {MyApp.AdminResolver, :get_on_duty, [:region]}
    ]
  ]

# Your resolver module:
defmodule MyApp.AdminResolver do
  def get_on_duty(region) do
    # Complex logic: check rotation schedule, time zones, etc.
    [admin: true, on_duty: true, region: region]
  end
end
```

**When to use:** Complex logic like on-call rotations, escalation chains

---

#### Format 6: System Audience (Static Recipients)

Static email addresses for system notifications:

```elixir
config :ash_dispatch,
  system_recipients: [
    %{email: "ops@myapp.com", name: "Operations"},
    %{email: "monitoring@pagerduty.com", name: "PagerDuty"}
  ]
```

**When to use:** External services, ops team emails

### Future-Proof Design

Adding new resources? **Zero code changes needed!**

```elixir
# Add a new Invoice resource
defmodule MyApp.Invoices.Invoice do
  # ...
  belongs_to :user, MyApp.Accounts.User
end

# Dispatch event with invoice
AshDispatch.Dispatcher.dispatch(
  "invoices.created",
  %{invoice: invoice}  # <-- User auto-extracted via relationship!
)
```

AshDispatch introspects the `Invoice` resource, finds the `:user` relationship, and extracts the user automatically.

## Real-World Example

Here's a complete event from production (Magasin):

```elixir
defmodule MyApp.Events.NewResellerRequest do
  use AshDispatch.Event

  @impl true
  def id, do: "requests.new_reseller_request"

  @impl true
  def channels(_context) do
    [
      # Send in-app notification to all admins
      %Channel{transport: :in_app, audience: :admin, time: {:in, 0}},

      # Send email to all admins
      %Channel{transport: :email, audience: :admin, time: {:in, 0}}
    ]
  end

  # NO recipients/2 override needed!
  # AshDispatch automatically:
  # 1. Queries MyApp.Accounts.User
  # 2. Filters by [super_admin: true]
  # 3. Extracts emails (handles CiString!)
  # 4. Sends to all admins
end
```

**Configuration:**
```elixir
config :ash_dispatch,
  user_module: MyApp.Accounts.User,
  admin_filter: [super_admin: true]
```

**That's it!** No resolver module, no hardcoded patterns, no maintenance.

## Audience Types

### `:user` - Extracted Automatically

AshDispatch finds the user via Ash introspection:

```elixir
# Works with direct user
%{user: %User{}}

# Works with nested user in any resource
%{order: %Order{user: %User{}}}
%{ticket: %Ticket{user: %User{}}}
%{invoice: %Invoice{user: %User{}}}
# ... any resource with a user relationship!
```

**How it works:**
1. Check if any data value IS the configured `user_module`
2. Use `Ash.Resource.Info.relationships/1` to find relationships to `user_module`
3. Extract user from that relationship

**Use when:**
- Notifying the person who triggered the action
- User-specific notifications
- Order confirmations, ticket updates, etc.

### `:admin` - Queried Automatically

AshDispatch queries admins using your configured filter:

```elixir
config :ash_dispatch,
  user_module: MyApp.Accounts.User,
  admin_filter: [super_admin: true]  # Your admin logic
```

**Examples:**
```elixir
# Simple boolean flag
admin_filter: [admin: true]

# Role-based
admin_filter: [role: :admin]

# Multiple conditions (keyword list becomes AND filter)
admin_filter: [active: true, role: :admin]
```

**Use when:**
- High-priority notifications
- Security alerts
- New user registrations
- System-wide announcements

### `:system` - Configured Recipients

Optional static recipients for system notifications:

```elixir
config :ash_dispatch,
  system_recipients: [
    %{email: "ops@myapp.com", name: "Operations"},
    %{email: "monitoring@pagerduty.com", name: "PagerDuty"}
  ]
```

**Use when:**
- Internal monitoring
- Ops team alerts
- External service integrations

## CiString Email Handling

AshDispatch automatically handles case-insensitive email types:

```elixir
# Your User resource
attribute :email, :ci_string  # or Ash.CiString, or CiString

# AshDispatch introspects attributes and handles:
%{string: "user@example.com"}  # CiString struct
%{data: "user@example.com"}    # Cldr.LanguageTag.CiString
"user@example.com"             # Plain string

# Zero configuration needed!
```

Uses `Ash.Resource.Info.attributes/1` to detect email type and extract correctly.

## Advanced: Custom Recipients

For the rare cases where you need custom logic (< 1% of events):

```elixir
defmodule MyApp.Events.EscalationAlert do
  use AshDispatch.Event

  @impl true
  def recipients(context, %Channel{audience: :admin}) do
    severity = context.data.alert.severity

    case severity do
      :critical ->
        # Critical: All admins + CTO
        MyApp.Accounts.User
        |> Ash.Query.filter_input(admin: true)
        |> Ash.Query.filter(role == :cto)
        |> Ash.read!()
        |> Enum.map(&normalize_user/1)

      _ ->
        # Default: Use smart defaults
        AshDispatch.Event.Helpers.resolve_recipients_for_audience(context, channel)
    end
  end

  defp normalize_user(user) do
    %{
      id: user.id,
      email: extract_email(user),
      display_name: user.display_name || user.email
    }
  end
end
```

**When to override:**
- Escalation chains based on severity
- Organization-scoped recipients
- On-call rotations
- Dynamic team assignment

**Otherwise:** Trust the smart defaults!

## Configuration Reference

### Complete Example

```elixir
config :ash_dispatch,
  # REQUIRED for user extraction and queries
  user_module: MyApp.Accounts.User,

  # Audience configuration supports multiple formats:
  recipient_filters: [
    audiences: [
      # Format 1: Bare atoms (extract from relationship with same name)
      :user,                      # Extract from :user relationship
      :creator,                   # Extract from :creator relationship

      # Format 2: Relationship path + filter (query users matching filter)
      admin: [:user, admin: true],
      partner: [:user, role: :partner, active: true],

      # Format 3: Relationship chain (follow multiple relationships)
      sellers: [:user, :associated_seller],
      team_lead: [:user, :team, :lead],

      # Format 4: Template filters (dynamic values from context)
      regional_admin: [:user, admin: true, region: {:resource, [:user, :region]}],

      # Format 5: Function/MFA (complex logic)
      on_duty: {MyApp.AdminResolver, :get_on_duty, []}

      # Format 6: System audience (configured separately below)
    ]
  ],

  # Static recipients for :system audience
  system_recipients: [
    %{email: "ops@example.com", name: "Operations"},
    %{email: "monitoring@pagerduty.com", name: "PagerDuty"}
  ]
```

### Format Quick Reference

| Format | Example | Use Case |
|--------|---------|----------|
| **Bare Atom** | `:user` | Extract from relationship with same name |
| **Relationship + Filter** | `admin: [:user, admin: true]` | Query users by attributes |
| **Relationship Chain** | `sellers: [:user, :associated_seller]` | Follow multiple relationships |
| **Template Filter** | `regional_admin: [:user, admin: true, region: {:resource, [...]}]` | Dynamic filters from context |
| **Function/MFA** | `on_duty: {Mod, :fun, []}` | Complex resolution logic |
| **System** | `system_recipients: [...]` | Static email addresses |

### Filter Query Examples

```elixir
# Simple boolean
admin: [:user, admin: true]

# Role-based
partner: [:user, role: :partner]

# Multiple conditions (AND)
active_admin: [:user, admin: true, active: true]

# Multiple values (OR - uses list)
manager: [:user, role: [:admin, :manager]]
```

### Template Filter Examples

```elixir
# Regional routing - admins in same region as user
regional_admin: [:user, admin: true, region: {:resource, [:user, :region]}]

# Team-based - users in same team
team_lead: [:user, role: :lead, team_id: {:resource, [:order, :team_id]}]

# Nested extraction
sales_manager: [:user, role: :manager, department: {:resource, [:user, :profile, :department]}]
```

## Extending DeliveryReceipt with User Relationship

AshDispatch provides a **Base module pattern** for creating DeliveryReceipt resources in your app with proper user relationships and TypeScript integration.

### Pattern 1: Base Module with Manual Relationship (Recommended)

The cleanest approach - use the Base module for all DSL, add your own relationships:

```elixir
defmodule MyApp.Deliveries.DeliveryReceipt do
  @moduledoc """
  Delivery receipt tracking - extends base from ash_dispatch with user relationship.
  """

  # Use base from ash_dispatch with ALL the DSL (attributes, actions, etc.)
  use AshDispatch.Resources.DeliveryReceipt.Base,
    repo: MyApp.Repo,
    domain: MyApp.Deliveries

  # TypeScript configuration (helps verifier detect AshTypescript.Resource extension)
  typescript do
    type_name("DeliveryReceipt")
  end

  # Add user relationship (only thing you need to define!)
  relationships do
    belongs_to :user, MyApp.Accounts.User do
      source_attribute :user_id
      destination_attribute :id
      allow_nil? true
      public? true
    end
  end
end
```

**What you get:**
- ✅ All attributes, actions, state machine from Base
- ✅ Explicit user relationship (clear ownership)
- ✅ TypeScript types with nested user support
- ✅ Full control over customization
- ✅ No magic - just clear module extension

---

### Pattern 2: Base Module with Auto Relationship

If you want the Base to create the relationship automatically:

```elixir
defmodule MyApp.Deliveries.DeliveryReceipt do
  use AshDispatch.Resources.DeliveryReceipt.Base,
    repo: MyApp.Repo,
    domain: MyApp.Deliveries,
    user_resource: MyApp.Accounts.User  # ← Auto-creates belongs_to :user

  # TypeScript types are automatically configured
  # User relationship is automatically added
end
```

**What happens:**
1. Base module injects all DSL (attributes, actions, policies, state machine)
2. If `user_resource` is provided, adds `belongs_to :user` relationship
3. Includes TypeScript extension automatically

---

### Base Module Benefits

**Compared to manual resource definition:**
- ❌ Manual: ~500 lines of duplicated DSL
- ✅ Base: ~20 lines for extension + relationships

**Compared to direct `use AshDispatch.Resources.DeliveryReceipt`:**
- ❌ Direct: No user relationship (library can't reference app modules)
- ✅ Base: Proper `belongs_to` relationship with your User module

**Features inherited from Base:**
- All attributes (event_id, transport, status, provider_response, etc.)
- State machine (pending → scheduled → sending → sent/failed)
- All actions (create, mark_sent, mark_failed, retry, etc.)
- Policies (workers bypass, admins can read)
- Calculations (oban_job)

---

### Usage in Your App

Once extended, use like any Ash resource:

```elixir
# Query receipts with user loaded
receipts = MyApp.Deliveries.DeliveryReceipt
|> Ash.Query.load(:user)
|> Ash.Query.filter(status == :sent)
|> Ash.read!()

# Create receipts (usually done by AshDispatch internally)
MyApp.Deliveries.DeliveryReceipt
|> Ash.Changeset.for_create(:create, %{
  event_id: "orders.created",
  transport: :email,
  user_id: user.id,
  recipient: user.email,
  status: :pending
})
|> Ash.create!()
```

---

### TypeScript Integration

With Pattern 1 (manual relationship), TypeScript types include the user:

```typescript
// Auto-generated from AshTypescript
interface DeliveryReceipt {
  id: string;
  event_id: string;
  transport: "email" | "in_app" | "discord";
  status: "pending" | "scheduled" | "sending" | "sent" | "failed";
  user_id: string;
  user?: User;  // ← Available for nested loading!
  recipient: string;
  subject?: string;
  body_html?: string;
  // ... all other fields
}

// Query with nested user
const receipts = await ashClient.query(DeliveryReceipt, {
  load: ["user"]
});
// receipts[0].user.email is available!
```

---

### Customization Examples

**Add custom policies:**

```elixir
defmodule MyApp.Deliveries.DeliveryReceipt do
  use AshDispatch.Resources.DeliveryReceipt.Base,
    repo: MyApp.Repo,
    domain: MyApp.Deliveries

  relationships do
    belongs_to :user, MyApp.Accounts.User do
      source_attribute :user_id
      destination_attribute :id
      allow_nil? true
      public? true
    end
  end

  # Add custom policies
  policies do
    # Users can read their own receipts
    policy action(:list_for_user) do
      authorize_if actor_attribute_equals(:id, arg(:user_id))
    end
  end
end
```

**Add custom actions:**

```elixir
defmodule MyApp.Deliveries.DeliveryReceipt do
  use AshDispatch.Resources.DeliveryReceipt.Base,
    repo: MyApp.Repo,
    domain: MyApp.Deliveries

  relationships do
    belongs_to :user, MyApp.Accounts.User do
      source_attribute :user_id
      destination_attribute :id
      allow_nil? true
      public? true
    end
  end

  # Add custom action
  actions do
    read :list_failed_for_retry do
      description "Find failed receipts ready for retry"

      filter expr(
        status == :failed and
        retry_count < 5 and
        (is_nil(last_retry_at) or last_retry_at < ago(15, :minute))
      )
    end
  end
end
```

---

### Migration from Direct Usage

**Before (if you were using the library resource directly):**
```elixir
# You couldn't - library doesn't know your User module
alias AshDispatch.Resources.DeliveryReceipt
```

**After (with Base pattern):**
```elixir
# In your app:
defmodule MyApp.Deliveries.DeliveryReceipt do
  use AshDispatch.Resources.DeliveryReceipt.Base,
    repo: MyApp.Repo,
    domain: MyApp.Deliveries

  relationships do
    belongs_to :user, MyApp.Accounts.User do
      source_attribute :user_id
      destination_attribute :id
      allow_nil? true
      public? true
    end
  end
end

# Now use your resource:
alias MyApp.Deliveries.DeliveryReceipt
```

This pattern allows AshDispatch to be **library-friendly** while providing **first-class relationships** in consuming apps!

---

## Migration from RecipientResolver

If you're migrating from the old `RecipientResolver` behaviour:

**Before (old pattern):**
```elixir
# lib/my_app/recipient_resolver.ex (130 lines of cond chains!)
defmodule MyApp.RecipientResolver do
  @behaviour AshDispatch.RecipientResolver

  def extract_user_id(%{data: data}) do
    cond do
      user = Map.get(data, :user) -> get_id(user)
      order = Map.get(data, :order) ->
        case Map.get(order, :user) do
          nil -> :error
          user -> get_id(user)
        end
      # ... 40+ more lines
    end
  end

  def resolve_admins(_context) do
    # Custom query logic
  end
end
```

**After (DSL-based pattern):**
```elixir
# config/config.exs (just configuration!)
config :ash_dispatch,
  user_module: MyApp.Accounts.User,
  recipient_filters: [
    audiences: [
      :user,
      admin: [:user, admin: true],
      partner: [:user, role: :partner]
    ]
  ]

# Delete lib/my_app/recipient_resolver.ex entirely
```

**Benefits:**
- ❌ Delete 130+ lines of brittle code
- ✅ Future-proof for new resources and audiences
- ✅ Zero maintenance - just update config
- ✅ Automatic CiString handling
- ✅ Works with ANY Ash resource structure
- ✅ Add new audiences without code changes

## Troubleshooting

### "No :user_module configured"

**Problem:** Warning logged when dispatching events.

**Cause:** Missing `user_module` configuration.

**Solution:**
```elixir
config :ash_dispatch,
  user_module: MyApp.Accounts.User
```

### "Failed to query admin recipients"

**Problem:** Error when dispatching to `:admin` audience.

**Cause:** Invalid `admin_filter` or User resource not queryable.

**Solution:**
1. Check `admin_filter` syntax matches your User attributes
2. Verify User resource has matching attribute
3. Check Ash read action is accessible

### "No user found in context"

**Problem:** Warning for `:user` audience events.

**Cause:** Event data doesn't contain user or resource with user relationship.

**Solution:**
1. Ensure event data includes user or related resource
2. Check resource has `belongs_to :user, YourUserModule`
3. Verify relationship is loaded if using nested extraction

### User Preferences Not Working

**Problem:** Users still receiving notifications they opted out of.

**Cause:** Preference checking requires additional setup.

**Solution:** See [User Preferences](user-preferences.md) guide.

## Performance Considerations

### Admin Query Caching

For frequently-dispatched admin events, consider caching:

```elixir
defmodule MyApp.AdminCache do
  use GenServer

  # Cache admin list, invalidate on user changes
  def get_admins do
    GenServer.call(__MODULE__, :get_admins)
  end

  def invalidate do
    GenServer.cast(__MODULE__, :invalidate)
  end
end

# In User resource
change fn changeset, _context ->
  if Ash.Changeset.changing_attribute?(changeset, :admin) do
    MyApp.AdminCache.invalidate()
  end
  changeset
end
```

### Relationship Preloading

If recipient resolution needs related data, preload in events:

```elixir
@impl true
def recipients(context, channel) do
  # Load relationships before normalizing
  AshDispatch.Event.Helpers.resolve_recipients_for_audience(context, channel)
  |> Ash.load!([:profile, :preferences])
end
```

## Testing

### Test Configuration

Use simpler filters in test environment:

```elixir
# config/test.exs
config :ash_dispatch,
  user_module: MyApp.Accounts.User,
  admin_filter: [test_admin: true]  # Use test-specific flag
```

### Factory Integration

Works seamlessly with test factories:

```elixir
test "dispatches to admins" do
  admin = build(:user, %{admin: true})
  insert!(admin)

  AshDispatch.Dispatcher.dispatch("events.admin_alert", %{data: %{}})

  # Verify admin received notification
  assert_email_sent(to: admin.email)
end
```

## Next Steps

- [Event Modules](events.md) - Define your events
- [Channel Configuration](channels.md) - Configure delivery channels
- [User Preferences](user-preferences.md) - Let users control notifications
- [Counter Broadcasting](counter-broadcasting.md) - Real-time updates
