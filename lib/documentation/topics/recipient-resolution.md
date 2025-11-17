# Recipient Resolution

AshDispatch automatically resolves recipients using **Ash introspection** - no custom resolver needed in 99% of cases!

##Quick Start (Zero Configuration!)

### 1. Configure Your App Structure

Tell AshDispatch about your User module and how to find admins:

```elixir
# config/config.exs
config :ash_dispatch,
  user_module: MyApp.Accounts.User,
  admin_filter: [admin: true]  # or [role: :admin], [super_admin: true], etc.
```

### 2. That's It!

AshDispatch now automatically:
- ✅ Finds users via Ash relationship introspection
- ✅ Queries admins using your filter
- ✅ Extracts emails (even CiString types!)
- ✅ Handles user preferences
- ✅ Works with ANY Ash resource structure

## How It Works

### Ash Introspection Magic

AshDispatch uses `Ash.Resource.Info` functions to automatically discover your app's structure:

**For `:user` audience:**
```elixir
# Your event data:
%{order: %Order{user: %User{}}}

# AshDispatch automatically:
# 1. Checks if any value IS the User module
# 2. Uses Ash.Resource.Info.relationships(Order) to find user relationship
# 3. Extracts the user - no hardcoded patterns!
```

**For `:admin` audience:**
```elixir
# AshDispatch automatically:
# 1. Queries your user_module
# 2. Applies your admin_filter
# 3. Returns all matching admins

# Equivalent to:
MyApp.Accounts.User
|> Ash.Query.filter_input(admin: true)
|> Ash.read!()
```

**For `:system` audience:**
```elixir
# Optional config:
config :ash_dispatch,
  system_recipients: [
    %{email: "ops@myapp.com", name: "Operations"}
  ]
```

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

```elixir
config :ash_dispatch,
  # REQUIRED for user extraction and admin queries
  user_module: MyApp.Accounts.User,

  # REQUIRED for :admin audience
  admin_filter: [admin: true],

  # OPTIONAL for :system audience
  system_recipients: [
    %{email: "ops@example.com", name: "Operations"}
  ]
```

### Multiple Admin Types

If you have multiple admin roles, use a more complex filter:

```elixir
# All these work with filter_input:
admin_filter: [role: :admin]
admin_filter: [super_admin: true, active: true]
admin_filter: [role: [:admin, :super_admin]]
```

For complex queries, override `recipients/2` in specific events.

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

**After (new pattern):**
```elixir
# config/config.exs (2 lines!)
config :ash_dispatch,
  user_module: MyApp.Accounts.User,
  admin_filter: [admin: true]

# Delete lib/my_app/recipient_resolver.ex
```

**Benefits:**
- ❌ Delete 130+ lines of brittle code
- ✅ Future-proof for new resources
- ✅ Zero maintenance
- ✅ Automatic CiString handling
- ✅ Works with ANY Ash resource structure

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
