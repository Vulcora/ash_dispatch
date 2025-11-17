# User Preferences

Allow users to control which notifications they receive by implementing preference checking.

## Overview

AshDispatch checks user preferences before delivering notifications, giving users control over their notification experience. Users can opt out of specific categories, transports, or combinations of both.

## Quick Start

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
  def user_allows?(user_id, event_id, transport, opts) do
    category = opts[:category]

    # Query your UserPreference resource
    case Ash.get(MyApp.Accounts.UserPreference, user_id) do
      {:ok, prefs} ->
        # Check if user disabled this category
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

## How It Works

### Preference Check Flow

```
1. Event triggers
2. Dispatcher creates DeliveryReceipt (status: :pending)
3. Transport checks AshDispatch.UserPreference.allows?()
   ├─ If false → Mark receipt :skipped (error: "user_opted_out")
   └─ If true → Continue with delivery
4. Delivery proceeds normally
```

**Key Point:** Receipts are always created for audit purposes, even if skipped.

### When Preferences Are Checked

**✅ Checked:**
- Events with `audience: :user`
- User-configurable events

**❌ Not Checked:**
- Events with `audience: :admin`
- Events with `audience: :team`
- Events with `audience: :system`
- System-critical notifications (auth, password reset)

## Preference Granularity

Users can control notifications at three levels:

### 1. By Category

Opt out of entire event categories:

```elixir
# In your UserPreference resource
attribute :disabled_categories, {:array, :atom}, default: []

# User opts out of marketing
user_preference.disabled_categories = [:marketing, :promotional]

# Events with category: :marketing will be skipped
```

### 2. By Transport

Opt out of specific delivery methods:

```elixir
attribute :disabled_transports, {:array, :atom}, default: []

# User opts out of all emails
user_preference.disabled_transports = [:email]

# User still gets :in_app notifications
```

### 3. Combined

Fine-grained control over category + transport combinations:

```elixir
def user_allows?(user_id, _event_id, transport, opts) do
  category = opts[:category]

  case Ash.get(UserPreference, user_id) do
    {:ok, prefs} ->
      # User can disable marketing emails but still get marketing in-app
      cond do
        {category, transport} in prefs.disabled_combinations ->
          false

        category in prefs.disabled_categories ->
          false

        transport in prefs.disabled_transports ->
          false

        true ->
          true
      end

    _ ->
      true
  end
end
```

## Event Categories

Define categories that make sense for your application:

**Common Categories:**
```elixir
:transactional    # Order confirmations, password resets (usually not configurable)
:marketing        # Promotional emails, product announcements
:billing          # Invoices, payment reminders
:social           # Comments, mentions, likes
:product_updates  # New features, changelogs
:system           # Maintenance notices, service updates
```

**Example Event Categorization:**
```elixir
dispatch do
  # Transactional - usually not user-configurable
  event :order_confirmed,
    metadata: [category: :transactional, user_configurable: false]

  # Marketing - user can opt out
  event :weekly_newsletter,
    metadata: [category: :marketing, user_configurable: true]

  # Social - user can control frequency
  event :comment_reply,
    metadata: [category: :social, user_configurable: true]
end
```

## Implementation Patterns

### Pattern 1: Simple Category Blocking

```elixir
defmodule MyApp.Preferences do
  @behaviour AshDispatch.UserPreference

  @impl true
  def user_allows?(user_id, _event_id, _transport, opts) do
    category = opts[:category]

    # Don't check preferences for critical categories
    if category in [:transactional, :security] do
      true
    else
      case get_user_preferences(user_id) do
        {:ok, prefs} -> category not in prefs.disabled_categories
        _ -> true
      end
    end
  end

  defp get_user_preferences(user_id) do
    MyApp.Accounts.UserPreference
    |> Ash.get(user_id)
  end
end
```

### Pattern 2: Transport-Specific Preferences

```elixir
@impl true
def user_allows?(user_id, _event_id, transport, opts) do
  category = opts[:category]

  case get_user_preferences(user_id) do
    {:ok, prefs} ->
      # Check transport-specific preferences
      case transport do
        :email ->
          prefs.email_enabled and category not in prefs.email_disabled_categories

        :in_app ->
          prefs.in_app_enabled and category not in prefs.in_app_disabled_categories

        :sms ->
          prefs.sms_enabled and category not in prefs.sms_disabled_categories

        _ ->
          true
      end

    _ ->
      true
  end
end
```

### Pattern 3: Frequency-Based Preferences

```elixir
@impl true
def user_allows?(user_id, event_id, transport, opts) do
  category = opts[:category]

  case get_user_preferences(user_id) do
    {:ok, prefs} ->
      # Check if user wants digest mode
      if digest_mode?(prefs, category) do
        # Don't send individual notifications, queue for digest
        queue_for_digest(user_id, event_id, category)
        false  # Skip individual delivery
      else
        # Check normal preferences
        category not in prefs.disabled_categories
      end

    _ ->
      true
  end
end

defp digest_mode?(prefs, category) do
  # User gets daily digest instead of individual emails
  prefs.digest_categories
  |> Enum.member?(category)
end
```

### Pattern 4: Time-Based Preferences

```elixir
@impl true
def user_allows?(user_id, _event_id, transport, opts) do
  category = opts[:category]

  case get_user_preferences(user_id) do
    {:ok, prefs} ->
      # Respect quiet hours
      if in_quiet_hours?(prefs) and category != :urgent do
        false  # Skip non-urgent notifications during quiet hours
      else
        category not in prefs.disabled_categories
      end

    _ ->
      true
  end
end

defp in_quiet_hours?(prefs) do
  now = Time.utc_now()
  quiet_start = prefs.quiet_hours_start || ~T[22:00:00]
  quiet_end = prefs.quiet_hours_end || ~T[08:00:00]

  Time.compare(now, quiet_start) != :lt and
  Time.compare(now, quiet_end) != :gt
end
```

## UserPreference Resource Example

Here's a complete UserPreference resource:

```elixir
defmodule MyApp.Accounts.UserPreference do
  use Ash.Resource,
    domain: MyApp.Accounts,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "user_preferences"
    repo MyApp.Repo
  end

  attributes do
    uuid_primary_key :id

    # User reference (no relationship to stay flexible)
    attribute :user_id, :uuid do
      allow_nil? false
    end

    # Category-based preferences
    attribute :disabled_categories, {:array, :atom}, default: []

    # Transport-based preferences
    attribute :email_enabled, :boolean, default: true
    attribute :in_app_enabled, :boolean, default: true
    attribute :sms_enabled, :boolean, default: false

    # Per-transport category preferences
    attribute :email_disabled_categories, {:array, :atom}, default: []
    attribute :in_app_disabled_categories, {:array, :atom}, default: []

    # Digest preferences
    attribute :digest_categories, {:array, :atom}, default: []
    attribute :digest_frequency, :atom, default: :daily  # :daily, :weekly

    # Quiet hours
    attribute :quiet_hours_start, :time
    attribute :quiet_hours_end, :time

    timestamps()
  end

  actions do
    defaults [:read, :update]

    create :create do
      accept [:user_id]
    end

    update :disable_category do
      accept []
      argument :category, :atom, allow_nil?: false

      change fn changeset, _ ->
        category = Ash.Changeset.get_argument(changeset, :category)
        current = Ash.Changeset.get_attribute(changeset, :disabled_categories) || []

        Ash.Changeset.change_attribute(
          changeset,
          :disabled_categories,
          Enum.uniq([category | current])
        )
      end
    end

    update :enable_category do
      accept []
      argument :category, :atom, allow_nil?: false

      change fn changeset, _ ->
        category = Ash.Changeset.get_argument(changeset, :category)
        current = Ash.Changeset.get_attribute(changeset, :disabled_categories) || []

        Ash.Changeset.change_attribute(
          changeset,
          :disabled_categories,
          List.delete(current, category)
        )
      end
    end
  end

  code_interface do
    define :create
    define :disable_category, args: [:category]
    define :enable_category, args: [:category]
  end

  identities do
    identity :unique_user_id, [:user_id]
  end
end
```

## Testing Preferences

### Test Your Preference Checker

```elixir
defmodule MyApp.PreferencesTest do
  use ExUnit.Case

  alias MyApp.NotificationPreferences

  setup do
    # Create test user with preferences
    user = create_user()

    {:ok, prefs} = UserPreference.create(%{
      user_id: user.id,
      disabled_categories: [:marketing],
      email_enabled: false
    })

    %{user: user, prefs: prefs}
  end

  test "user who disabled marketing category", %{user: user} do
    # Should block marketing
    refute NotificationPreferences.user_allows?(
      user.id,
      "promo.new",
      :email,
      category: :marketing
    )

    # Should allow transactional
    assert NotificationPreferences.user_allows?(
      user.id,
      "order.created",
      :email,
      category: :transactional
    )
  end

  test "user who disabled email transport", %{user: user} do
    # Should block all emails
    refute NotificationPreferences.user_allows?(
      user.id,
      "any.event",
      :email,
      category: :billing
    )

    # Should allow in-app
    assert NotificationPreferences.user_allows?(
      user.id,
      "any.event",
      :in_app,
      category: :billing
    )
  end
end
```

### Integration Tests

```elixir
test "opted-out user gets receipt marked as skipped" do
  user = create_opted_out_user()

  # Trigger event
  {:ok, product} = create_product(%{user_id: user.id})

  # Check receipt was created but skipped
  receipts = DeliveryReceipt
    |> Ash.Query.filter(event_id == "product.created")
    |> Ash.read!()

  assert length(receipts) == 1
  assert hd(receipts).status == :skipped
  assert hd(receipts).error_message == "user_opted_out"

  # Verify no notification created
  notifications = Notification
    |> Ash.Query.filter(user_id == ^user.id)
    |> Ash.read!()

  assert length(notifications) == 0
end
```

## UI Integration

### Preference Settings Page

```elixir
# LiveView component
defmodule MyAppWeb.PreferencesLive do
  use MyAppWeb, :live_view

  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok, prefs} = UserPreference.get_or_create(user.id)

    {:ok,
     socket
     |> assign(:preferences, prefs)
     |> assign(:categories, available_categories())}
  end

  def handle_event("toggle_category", %{"category" => category}, socket) do
    category_atom = String.to_existing_atom(category)
    user_id = socket.assigns.current_user.id

    if category_atom in socket.assigns.preferences.disabled_categories do
      UserPreference.enable_category(user_id, category_atom)
    else
      UserPreference.disable_category(user_id, category_atom)
    end

    {:ok, prefs} = UserPreference.get(user_id)
    {:noreply, assign(socket, :preferences, prefs)}
  end

  defp available_categories do
    [
      %{key: :marketing, label: "Marketing & Promotions", description: "Product announcements, special offers"},
      %{key: :billing, label: "Billing & Payments", description: "Invoices, payment reminders"},
      %{key: :social, label: "Social Activity", description: "Comments, mentions, likes"},
      %{key: :product_updates, label: "Product Updates", description: "New features, changelogs"}
    ]
  end
end
```

## Best Practices

### 1. Always Allow Critical Notifications

```elixir
def user_allows?(user_id, event_id, transport, opts) do
  category = opts[:category]

  # Never block critical system notifications
  if category in [:security, :transactional] do
    true
  else
    check_user_preferences(user_id, category, transport)
  end
end
```

### 2. Default to Opt-In for New Categories

```elixir
def user_allows?(user_id, _event_id, _transport, opts) do
  category = opts[:category]

  case get_user_preferences(user_id) do
    {:ok, prefs} ->
      # If category is unknown, allow (opt-in by default)
      if category in known_categories() do
        category not in prefs.disabled_categories
      else
        true
      end

    _ ->
      true
  end
end
```

### 3. Provide Clear Category Descriptions

Make it easy for users to understand what they're opting out of:

```elixir
@category_descriptions %{
  marketing: "Promotional emails, product announcements, special offers",
  billing: "Invoices, payment reminders, subscription updates",
  social: "Comments, mentions, likes, and other social interactions",
  system: "Important system announcements and maintenance notices"
}
```

### 4. Log Preference Decisions

```elixir
def user_allows?(user_id, event_id, transport, opts) do
  result = check_preferences(user_id, event_id, transport, opts)

  unless result do
    Logger.info("""
    User #{user_id} opted out of notification
    Event: #{event_id}
    Transport: #{transport}
    Category: #{opts[:category]}
    """)
  end

  result
end
```

## Performance Considerations

### Caching

User preferences are read-heavy. Consider caching:

```elixir
defmodule MyApp.PreferenceCache do
  use Nebulex.Cache,
    otp_app: :my_app,
    adapter: Nebulex.Adapters.Local
end

def user_allows?(user_id, _event_id, transport, opts) do
  category = opts[:category]
  cache_key = {:user_prefs, user_id}

  prefs = PreferenceCache.get(cache_key, fn ->
    case get_user_preferences(user_id) do
      {:ok, prefs} -> prefs
      _ -> nil
    end
  end)

  check_preferences(prefs, category, transport)
end
```

### Batch Checking

For multi-recipient events:

```elixir
def batch_allows?(user_ids, event_id, transport, opts) when is_list(user_ids) do
  # Fetch all preferences in one query
  prefs = UserPreference
    |> Ash.Query.filter(user_id in ^user_ids)
    |> Ash.read!()
    |> Map.new(&{&1.user_id, &1})

  # Return map of user_id => boolean
  Map.new(user_ids, fn user_id ->
    pref = Map.get(prefs, user_id)
    {user_id, check_single_preference(pref, event_id, transport, opts)}
  end)
end
```

## Troubleshooting

### Preferences Not Being Respected

1. **Check configuration:**
   ```elixir
   config :ash_dispatch, user_preference: MyApp.Preferences
   ```

2. **Verify callback implementation:**
   ```elixir
   @behaviour AshDispatch.UserPreference
   @impl true
   def user_allows?(...) do
     # Implementation here
   end
   ```

3. **Check event category:**
   ```elixir
   metadata: [category: :marketing]
   ```

### All Notifications Being Skipped

Check that your `user_allows?/4` isn't accidentally returning `false` for all cases:

```elixir
# Add logging
def user_allows?(user_id, event_id, transport, opts) do
  result = check_preferences(...)

  Logger.debug("""
  Preference check:
    User: #{user_id}
    Event: #{event_id}
    Transport: #{transport}
    Result: #{result}
  """)

  result
end
```

## See Also

- [Recipient Resolution](recipient-resolution.md) - Finding notification recipients
- [Getting Started](../tutorials/getting-started.md) - Basic setup
- [DSL Reference](../dsls/DSL-AshDispatch-Resource.md) - Event configuration
