# Recipient Resolution

AshDispatch resolves recipients using **DSL-based configuration** - define once, works everywhere!

## Quick Start

### Configure Your Audiences

```elixir
# config/config.exs
config :ash_dispatch,
  user_module: MyApp.Accounts.User,
  audiences: [
    # Simple: extract from relationship
    :user,

    # Filter: query all matching users
    admin: [:user, admin: true],

    # Dynamic: call your resolver for complex logic
    company_members: {MyApp.AudienceResolver, :company_members, [:resource]}
  ]
```

### That's It!

AshDispatch automatically:
- ✅ Resolves recipients from relationships or queries
- ✅ Handles complex scenarios via MFA (module/function/args)
- ✅ Works with counters, events, and notifications
- ✅ Extracts emails (handles CiString!)
- ✅ Respects user preferences

## Audience Formats

AshDispatch supports six audience formats, from simple to powerful:

| Format | Example | Use Case |
|--------|---------|----------|
| **Bare Atom** | `:user` | Single recipient from relationship |
| **Filter** | `admin: [:user, admin: true]` | All users matching criteria |
| **Chain** | `lead: [:user, :team, :lead]` | Follow relationship chain |
| **Template** | `regional: [:user, region: {:resource, [...]}]` | Dynamic filter values |
| **MFA** | `company: {Mod, :fun, [:resource]}` | Full custom logic |
| **System** | `system_recipients: [...]` | Static recipients |

### Choosing the Right Format

```
Need to notify...

ONE person (order owner, ticket assignee)?
  → Use Bare Atom: :user, :assignee, :creator

ALL users matching criteria (admins, partners)?
  → Use Filter: admin: [:user, admin: true]

DYNAMIC group based on record (company members, team)?
  → Use MFA: company: {Resolver, :members, [:resource]}
```

---

## Format 1: Bare Atom (Relationship Extraction)

The simplest format - extract a single recipient from a named relationship:

```elixir
audiences: [
  :user,      # Extract from :user relationship
  :creator,   # Extract from :creator relationship
  :assignee   # Extract from :assignee relationship
]
```

**How it works:**
1. Find the named relationship on the resource
2. Extract the related user
3. Return as single recipient

**Example:**
```elixir
# Order has belongs_to :user
%{order: %Order{user: %User{email: "customer@example.com"}}}

# audience: :user → extracts the order's user
```

**Use when:** Notifying the person who owns/created/is assigned to the resource.

---

## Format 2: Filter (Query All Matching Users)

Query all users matching attribute filters:

```elixir
audiences: [
  admin: [:user, admin: true],
  support: [:user, role: :support],
  active_partners: [:user, role: :partner, active: true]
]
```

**How it works:**
1. Query `user_module` with the filter
2. Return all matching users as recipients

**Example:**
```elixir
# admin: [:user, admin: true]
# → Queries: User |> filter(admin == true)
# → Returns all admin users
```

**Use when:** Broadcasting to all users in a role (admins, support, partners).

---

## Format 3: Relationship Chain

Follow multiple relationships to reach recipients:

```elixir
audiences: [
  team_lead: [:user, :team, :lead],
  seller: [:user, :associated_seller]
]
```

**How it works:**
1. Extract first relationship from resource
2. Follow chain to final recipient

**Example:**
```elixir
# Order.user.team.lead
team_lead: [:user, :team, :lead]
```

**Use when:** Recipients accessible via relationship chains.

---

## Format 4: Template Filter (Dynamic Values)

Filters with values extracted from the resource:

```elixir
audiences: [
  regional_admin: [:user, admin: true, region: {:resource, [:user, :region]}]
]
```

**How it works:**
1. Extract value from resource path (e.g., `user.region`)
2. Substitute into filter
3. Query users matching dynamic filter

**Example:**
```elixir
# For order with user.region = "EU"
regional_admin: [:user, admin: true, region: {:resource, [:user, :region]}]
# → Queries: User |> filter(admin == true and region == "EU")
```

**Use when:** Regional routing, team-scoped notifications.

---

## Format 5: MFA (Full Dynamic Logic)

**The most powerful format** - call your own function for complex resolution:

```elixir
audiences: [
  company_members: {MyApp.AudienceResolver, :company_members, [:resource]},
  on_duty: {MyApp.OnCallResolver, :current_on_call, []},
  escalation: {MyApp.EscalationResolver, :get_chain, [:resource]}
]
```

### How MFA Works

1. AshDispatch calls your function with resolved args
2. `:resource` placeholder is replaced with the actual record
3. Your function returns recipients (users, IDs, or filters)

### MFA Return Types

Your function can return any of these:

```elixir
# Return user structs/maps with :id
def my_resolver(record) do
  [%{id: "user-1"}, %{id: "user-2"}]
end

# Return list of user IDs (strings)
def my_resolver(record) do
  ["user-1", "user-2", "user-3"]
end

# Return a filter to query users
def my_resolver(record) do
  [team_id: record.team_id, role: :member]
end
```

### Real-World Example: Company Members

This pattern solves organization-scoped notifications - where company owners and employees should all see the same data:

```elixir
# config/config.exs
config :ash_dispatch,
  audiences: [
    company_members: {MyApp.Accounts.AudienceResolver, :company_members, [:resource]}
  ]

# lib/my_app/accounts/audience_resolver.ex
defmodule MyApp.Accounts.AudienceResolver do
  @moduledoc """
  Dynamic audience resolution for organization-scoped recipients.
  """

  require Ash.Query

  @doc """
  Resolves all company members for a record.

  Company membership is determined by owner_id relationship:
  - Owners see their own + all employees' resources
  - Employees see their own + owner's + siblings' resources
  """
  def company_members(nil), do: []

  def company_members(record) do
    user_id = Map.get(record, :user_id)
    if is_nil(user_id), do: [], else: get_company_member_ids(user_id)
  end

  defp get_company_member_ids(user_id) do
    case get_user(user_id) do
      {:ok, user} when not is_nil(user) ->
        member_ids = get_members_for_user(user)
        # Return as user maps with :id field
        Enum.map(member_ids, fn id -> %{id: id} end)
      _ ->
        [%{id: user_id}]
    end
  end

  defp get_members_for_user(user) do
    cond do
      # Owner: self + all employees
      user.company_role == :owner ->
        [user.id | get_employee_ids(user.id)] |> Enum.uniq()

      # Employee: self + owner + siblings
      user.company_role == :employee && user.owner_id ->
        [user.id, user.owner_id | get_employee_ids(user.owner_id)] |> Enum.uniq()

      # No company: just self
      true ->
        [user.id]
    end
  end

  defp get_employee_ids(owner_id) do
    MyApp.Accounts.User
    |> Ash.Query.filter(owner_id == ^owner_id and company_role == :employee)
    |> Ash.Query.select([:id])
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.id)
  end

  defp get_user(user_id) do
    MyApp.Accounts.User
    |> Ash.Query.filter(id == ^user_id)
    |> Ash.Query.select([:id, :company_role, :owner_id])
    |> Ash.read_one(authorize?: false)
  end
end
```

### Using MFA with Counters

MFA audiences work seamlessly with the counter DSL:

```elixir
# In your resource
counters do
  counter :pending_orders,
    trigger_on: [:create, :update_status],
    query_filter: [status: :pending],
    audience: :company_members,  # ← MFA audience
    group: :orders,
    invalidates: ["orders"]
end
```

When an order is created:
1. Counter broadcasts to `:company_members` audience
2. `AudienceResolver.company_members/1` receives the order record
3. Returns all company member IDs
4. Each member receives the counter update
5. Counter query uses Ash authorization (your policies scope the count)

### Other MFA Use Cases

**On-call rotation:**
```elixir
def current_on_call(_record) do
  schedule = OnCallSchedule.get_current()
  [%{id: schedule.primary_id}, %{id: schedule.secondary_id}]
end
```

**Escalation chain:**
```elixir
def escalation_chain(record) do
  case record.severity do
    :critical -> get_all_leads() ++ get_cto()
    :high -> get_team_lead(record.team_id)
    _ -> []
  end
end
```

**Geographic routing:**
```elixir
def regional_support(record) do
  region = record.user.region
  [region: region, role: :support, on_duty: true]  # Returns filter
end
```

---

## Format 6: System (Static Recipients)

Static recipients for system notifications:

```elixir
config :ash_dispatch,
  system_recipients: [
    %{email: "ops@myapp.com", name: "Operations"},
    %{email: "alerts@pagerduty.com", name: "PagerDuty"}
  ]
```

**Use when:** External services, monitoring, ops team.

---

## How Context Flows to MFA

When AshDispatch calls your MFA function, the `:resource` placeholder receives:

**For Events:**
```elixir
# The primary resource from context.data
%{order: order, user: user}  # → order is passed to MFA
```

**For Counters:**
```elixir
# The record that triggered the counter
order = Ash.create!(Order, ...)  # → order is passed to MFA
```

This enables MFA functions to make decisions based on the actual data.

---

## Configuration Reference

### Complete Example

```elixir
config :ash_dispatch,
  # Required: Your user module
  user_module: MyApp.Accounts.User,

  # Audience definitions
  audiences: [
    # Format 1: Bare atom (relationship extraction)
    :user,
    :creator,

    # Format 2: Filter (query all matching)
    admin: [:user, admin: true],
    support: [:user, role: :support],

    # Format 3: Relationship chain
    team_lead: [:user, :team, :lead],

    # Format 4: Template filter (dynamic values)
    regional_admin: [:user, admin: true, region: {:resource, [:user, :region]}],

    # Format 5: MFA (full custom logic)
    company_members: {MyApp.AudienceResolver, :company_members, [:resource]},
    on_duty: {MyApp.OnCallResolver, :current, []}
  ],

  # Format 6: System recipients
  system_recipients: [
    %{email: "ops@myapp.com", name: "Operations"}
  ]
```

### When to Use Each Format

| Scenario | Format | Example |
|----------|--------|---------|
| Order confirmation to buyer | Bare Atom | `:user` |
| Alert all admins | Filter | `admin: [:user, admin: true]` |
| Notify team lead | Chain | `lead: [:user, :team, :lead]` |
| Regional admin routing | Template | `regional: [:user, admin: true, region: {:resource, ...}]` |
| Organization-wide visibility | MFA | `company: {Resolver, :members, [:resource]}` |
| External monitoring | System | `system_recipients: [...]` |

---

## Combining with Ash Policies

MFA audiences work best when combined with Ash policies for authorization:

```elixir
# 1. MFA audience broadcasts to all company members
audiences: [
  company_members: {AudienceResolver, :company_members, [:resource]}
]

# 2. Counter uses this audience
counter :pending_orders,
  audience: :company_members,
  # authorize?: true is default - uses policies for scoping
  ...

# 3. Policy filters results per-user
policies do
  policy action_type(:read) do
    authorize_if SameCompanyCheck  # Your filter check
  end
end
```

**Result:**
- All company members receive counter broadcasts
- Each member's count is scoped by the policy
- Owner sees: owner's orders + employees' orders
- Employee sees: own orders + owner's orders + siblings' orders

---

## Troubleshooting

### "No :user_module configured"

```elixir
config :ash_dispatch,
  user_module: MyApp.Accounts.User
```

### MFA function not found

Check the function is exported with correct arity:

```elixir
# Config
company: {MyApp.Resolver, :members, [:resource]}

# Must export: members/1
def members(resource), do: ...
```

### No recipients resolved

1. Check MFA function returns proper format (user maps, IDs, or filter)
2. Verify `:resource` placeholder if using it
3. Add logging to your resolver to debug

### Counter not broadcasting to all members

1. Ensure audience is NOT a bare atom (those extract single recipient)
2. Use MFA or filter-based audience for multiple recipients
3. Check your MFA function returns all expected IDs

---

## Testing MFA Resolvers

```elixir
describe "company_members/1" do
  test "returns owner and all employees" do
    owner = create_user(company_role: :owner)
    emp1 = create_user(company_role: :employee, owner_id: owner.id)
    emp2 = create_user(company_role: :employee, owner_id: owner.id)

    order = create_order(user_id: emp1.id)

    result = AudienceResolver.company_members(order)
    ids = Enum.map(result, & &1.id)

    assert owner.id in ids
    assert emp1.id in ids
    assert emp2.id in ids
  end

  test "handles nil record" do
    assert AudienceResolver.company_members(nil) == []
  end
end
```

---

## Next Steps

- [Counter Broadcasting](counter-broadcasting.md) - Real-time updates with audiences
- [User Preferences](user-preferences.md) - Let users control notifications
- [Phoenix Integration](phoenix-integration.md) - Channel and frontend setup
