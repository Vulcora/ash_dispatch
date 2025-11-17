# Recipient Resolution

AshDispatch needs to know how to find recipients for different audience types (admin, team, system). Since AshDispatch doesn't know about your User resource, you provide a resolver module.

## Quick Start

### 1. Create a Resolver Module

```elixir
# lib/my_app/recipients/resolver.ex
defmodule MyApp.Recipients.Resolver do
  @behaviour AshDispatch.RecipientResolver

  alias MyApp.Accounts.User

  @impl true
  def resolve_admins(_context) do
    User
    |> Ash.Query.filter(admin == true)
    |> Ash.read!()
  end

  @impl true
  def resolve_team(team_name, _context) do
    case team_name do
      :support ->
        User
        |> Ash.Query.filter(role == :support)
        |> Ash.read!()

      :engineering ->
        User
        |> Ash.Query.filter(department == "Engineering")
        |> Ash.read!()

      _ ->
        []
    end
  end

  @impl true
  def resolve_system(_context) do
    # System notifications go to ops team
    [
      %{email: "ops@myapp.com", name: "Operations"}
    ]
  end
end
```

### 2. Configure the Resolver

```elixir
# config/config.exs
config :ash_dispatch,
  recipient_resolver: MyApp.Recipients.Resolver
```

### 3. Use in Events

```elixir
dispatch do
  event :critical_error,
    trigger_on: :fail,
    channels: [
      # Notify all admins
      [transport: :email, audience: :admin],

      # Notify support team
      [transport: :in_app, audience: :team, team: :support],

      # Notify ops (system)
      [transport: :discord, audience: :system]
    ]
end
```

## Audience Types

### `:user` - Current User

The `:user` audience automatically resolves to `context.user`:

```elixir
channels: [
  [transport: :email, audience: :user]
]

# AshDispatch will send to context.user
# No resolver callback needed
```

**Use when:**
- Notifying the person who triggered the action
- User-specific notifications

### `:admin` - Admin Users

The `:admin` audience calls `resolve_admins/1`:

```elixir
channels: [
  [transport: :email, audience: :admin]
]

# Calls: MyApp.Recipients.Resolver.resolve_admins(context)
```

**Use when:**
- High-priority notifications
- Security alerts
- System-wide announcements

### `:team` - Team Members

The `:team` audience calls `resolve_team/2` with team name:

```elixir
channels: [
  [transport: :in_app, audience: :team, team: :support]
]

# Calls: MyApp.Recipients.Resolver.resolve_team(:support, context)
```

**Use when:**
- Department-specific notifications
- Role-based alerts
- Cross-functional team updates

### `:system` - Operations/Monitoring

The `:system` audience calls `resolve_system/1`:

```elixir
channels: [
  [transport: :webhook, audience: :system]
]

# Calls: MyApp.Recipients.Resolver.resolve_system(context)
```

**Use when:**
- Internal monitoring
- Ops team alerts
- System health notifications

## Context-Aware Resolution

The `context` parameter contains event data for dynamic resolution:

```elixir
@impl true
def resolve_admins(context) do
  # Only notify admins in the same organization
  case context.data.order do
    %{organization_id: org_id} when not is_nil(org_id) ->
      User
      |> Ash.Query.filter(admin == true and organization_id == ^org_id)
      |> Ash.read!()

    _ ->
      # Global admins
      User
      |> Ash.Query.filter(admin == true)
      |> Ash.read!()
  end
end
```

**Context fields:**
- `event_id` - Event identifier ("orders.created")
- `data` - Event data (resource record, etc.)
- `user` - Current user (if available)
- `metadata` - Additional context
- `base_url` - Application base URL
- `locale` - User locale

## Advanced Patterns

### Organization-Scoped Teams

```elixir
@impl true
def resolve_team(:support, context) do
  org_id = context.data.ticket.organization_id

  User
  |> Ash.Query.filter(
    role == :support and
    organization_id == ^org_id
  )
  |> Ash.read!()
end
```

### On-Call Rotations

```elixir
@impl true
def resolve_team(:on_call, context) do
  # Get current on-call engineer from schedule
  schedule = OnCallSchedule.current()

  User
  |> Ash.get!(schedule.engineer_id)
  |> then(&[&1])
end
```

### Escalation Chains

```elixir
@impl true
def resolve_admins(context) do
  severity = context.metadata[:severity]

  case severity do
    :critical ->
      # All admins + CTO
      User
      |> Ash.Query.filter(admin == true or role == :cto)
      |> Ash.read!()

    :high ->
      # Just admins
      User
      |> Ash.Query.filter(admin == true)
      |> Ash.read!()

    _ ->
      # Support leads only
      User
      |> Ash.Query.filter(role == :support_lead)
      |> Ash.read!()
  end
end
```

### External Recipients

You don't need to return Ash records - any map with `:email` works:

```elixir
@impl true
def resolve_system(_context) do
  [
    %{email: "ops@myapp.com", name: "Ops Team"},
    %{email: "monitoring@pagerduty.com", name: "PagerDuty"}
  ]
end
```

## Multiple Recipients

All resolver callbacks should return lists. AshDispatch will send to each recipient:

```elixir
@impl true
def resolve_admins(_context) do
  User
  |> Ash.Query.filter(admin == true)
  |> Ash.read!()
  # Returns [user1, user2, user3, ...]
  # Each will receive the notification
end
```

## Default Behavior (No Resolver)

If you don't configure a resolver, AshDispatch uses `AshDispatch.RecipientResolver.Default` which:

1. Returns `[]` for admin/team/system audiences
2. Logs warnings to help you realize you need a resolver
3. Doesn't break your app

**Example warning:**

```
[warning] Admin recipient resolution not implemented!

To enable admin notifications, configure a recipient resolver:

    # config/config.exs
    config :ash_dispatch,
      recipient_resolver: MyApp.Recipients.Resolver
```

## Testing

### Test Resolver

Create a test-only resolver that returns mock data:

```elixir
# test/support/test_recipient_resolver.ex
defmodule MyApp.Test.RecipientResolver do
  @behaviour AshDispatch.RecipientResolver

  @impl true
  def resolve_admins(_context) do
    [
      %{id: 1, email: "admin@test.com", name: "Test Admin"}
    ]
  end

  @impl true
  def resolve_team(:support, _context) do
    [
      %{id: 2, email: "support@test.com", name: "Test Support"}
    ]
  end

  @impl true
  def resolve_system(_context) do
    [%{email: "ops@test.com"}]
  end
end
```

Configure in `config/test.exs`:

```elixir
config :ash_dispatch,
  recipient_resolver: MyApp.Test.RecipientResolver
```

### Testing with Factories

Use factories to build realistic test users:

```elixir
defmodule MyApp.Recipients.Resolver do
  @impl true
  def resolve_admins(_context) do
    if Mix.env() == :test do
      # Use factory in tests
      [build(:user, %{admin: true})]
    else
      # Real query in dev/prod
      User
      |> Ash.Query.filter(admin == true)
      |> Ash.read!()
    end
  end
end
```

## Performance Considerations

### Caching

For frequently-accessed recipients (e.g., all admins), consider caching:

```elixir
@impl true
def resolve_admins(_context) do
  ConCache.get_or_store(:recipients, :admins, fn ->
    User
    |> Ash.Query.filter(admin == true)
    |> Ash.read!()
  end)
end
```

Invalidate cache when admins change:

```elixir
# In User resource
change fn changeset, _context ->
  if Ash.Changeset.changing_attribute?(changeset, :admin) do
    ConCache.delete(:recipients, :admins)
  end
  changeset
end
```

### Preloading

If your notifications need user relationships, preload them:

```elixir
@impl true
def resolve_admins(_context) do
  User
  |> Ash.Query.filter(admin == true)
  |> Ash.Query.load([:profile, :preferences])
  |> Ash.read!()
end
```

Then access in event modules:

```elixir
def notification_message(context, _channel) do
  admin = context.user  # Already preloaded
  "Hello #{admin.profile.display_name}!"
end
```

## Troubleshooting

### "No recipients after filtering"

**Problem:** Resolver returns users, but no notifications sent.

**Cause:** Likely user preference filtering (coming soon).

**Solution:** Check event configuration and user preferences.

### "Unknown audience type"

**Problem:** Warning about unknown audience.

**Cause:** Typo in channel configuration.

**Solution:** Check spelling - must be `:user`, `:admin`, `:team`, or `:system`.

### "resolve_team/2 is undefined"

**Problem:** Configured resolver doesn't implement `resolve_team/2`.

**Cause:** Missing callback implementation.

**Solution:** Implement all three callbacks even if some return `[]`:

```elixir
@impl true
def resolve_team(_team_name, _context), do: []
```

## Next Steps

- [Channel Configuration](channels.md) - Configure delivery channels
- [Event Modules](events.md) - Custom recipient logic in event modules
- [User Preferences](user-preferences.md) - Let users control notifications
