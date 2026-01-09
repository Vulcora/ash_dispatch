# Recipient Resolution

Define how notification recipients are resolved for each audience using a declarative DSL.

## Overview

AshDispatch uses a behaviour-based approach for recipient resolution, following Ash Framework patterns. Instead of scattered MFA configurations, you define all your audiences in a single module using a declarative DSL.

## Quick Start

### 1. Generate a Resolver

```bash
mix ash_dispatch.gen.recipient_resolver MyApp.RecipientResolver
```

This creates a module with example audiences and configures `config.exs` automatically.

### 2. Define Your Audiences

```elixir
defmodule MyApp.RecipientResolver do
  use AshDispatch.RecipientResolver,
    user_resource: MyApp.Accounts.User

  audiences do
    # Extract user from event context
    audience :user, from_context: :user

    # Query users with admin role
    audience :admins, query: [role: :admin, is_active: true]

    # Custom resolver for complex logic
    audience :owner, resolve: :resolve_owner

    # Combine multiple audiences
    audience :stakeholders, combine: [:owner, :team]
  end

  @impl true
  def to_recipient(%MyApp.Accounts.User{} = user) do
    %{
      id: user.id,
      email: to_string(user.email),
      display_name: user.full_name || to_string(user.email)
    }
  end

  def resolve_owner(resource, context) do
    # Your custom logic here
    case Map.get(context.data, :project) do
      nil -> []
      project -> get_project_owner(project)
    end
  end
end
```

### 3. Configure ash_dispatch

```elixir
# config/config.exs
config :ash_dispatch,
  recipient_resolver: MyApp.RecipientResolver
```

### 4. Use Audiences in Events

```elixir
dispatch do
  event :order_created do
    channel :in_app, audience: :owner
    channel :email, audience: :team
    channel :email, audience: :admins
  end
end
```

## Resolution Strategies

AshDispatch provides five built-in resolution strategies:

### `from_context` - Extract from Event Context

The simplest strategy - extracts recipients directly from `context.data`.

```elixir
# Single key - extracts context.data.user
audience :user, from_context: :user

# Fallback chain - tries :user first, then :assignee
audience :assignee, from_context: [:user, :assignee]

# Path + extract - gets context.data.meeting.participants, extracts :user from each
audience :participants, from_context: [:meeting, :participants], extract: :user
```

**When to use:** For recipients that are already loaded in the event context.

### `query` - Query User Resource

Queries your user resource using Ash filters.

```elixir
# Find all active admins
audience :admins, query: [role: :admin, is_active: true]

# Find users by type
audience :customers, query: [user_type: :customer]

# Complex filter
audience :premium_users, query: [subscription_tier: :premium, email_verified: true]
```

**When to use:** For role-based or attribute-based audiences that don't depend on the event resource.

### `path` - Follow Relationship Path

Traverses relationships starting from the event resource.

```elixir
# Get users through customer relationship
audience :customer_users, path: [:customer, :customer_users, :user]

# Get team members through project
audience :project_team, path: [:project, :team_members]
```

**When to use:** For recipients reachable through relationships on the resource.

### `combine` - Union of Audiences

Combines multiple audiences, deduplicating by recipient ID.

```elixir
# Owner + team members
audience :stakeholders, combine: [:owner, :team]

# All involved parties
audience :all_parties, combine: [:owner, :team, :customer_users]
```

**When to use:** For composite audiences that should include multiple groups.

### `resolve` - Custom Resolver

For complex business logic that doesn't fit other strategies.

```elixir
# Function in the resolver module
audience :owner, resolve: :resolve_owner

# Function in another module
audience :specialists, resolve: {MyApp.Specialists, :resolve}

# With extra arguments
audience :leads, resolve: {MyApp.Leads, :resolve, [:active_only]}

# Raw output (skip to_recipient conversion)
audience :lead_contact, resolve: :resolve_lead_contact, raw: true
```

**When to use:** For RoleAssignment lookups, complex queries, or non-user recipients.

## The `to_recipient/1` Callback

Every resolver must implement `to_recipient/1` to convert user structs to recipient maps:

```elixir
@impl true
def to_recipient(%MyApp.Accounts.User{} = user) do
  %{
    id: user.id,                    # Required - for deduplication
    email: to_string(user.email),   # Required - for email transport
    display_name: format_name(user), # Optional - for templates
    first_name: user.first_name     # Optional - for personalization
  }
end

defp format_name(user) do
  cond do
    user.full_name -> user.full_name
    user.first_name -> user.first_name
    true -> to_string(user.email)
  end
end
```

**Default implementation:** If you don't define `to_recipient/1`, a default implementation extracts `:id`, `:email`, and `:full_name`/`:first_name` from the user struct.

## The `raw` Option

For audiences that return pre-formatted recipient maps instead of user structs:

```elixir
# Returns maps directly, skips to_recipient conversion
audience :lead_contact, resolve: :resolve_lead_contact, raw: true

def resolve_lead_contact(resource, _context) do
  case resource do
    %Lead{contact_email: email, contact_name: name} when not is_nil(email) ->
      [%{
        id: resource.id,
        email: email,
        display_name: name || "there"
      }]
    _ ->
      []
  end
end
```

**When to use:** For non-user recipients like lead contacts, external emails, or webhook targets.

## Custom Resolvers

Custom resolver functions receive `(resource, context)` and return a list of users (or maps if `raw: true`):

```elixir
def resolve_owner(resource, context) do
  cond do
    # Check for project in resource or context
    project = extract_project(resource, context) ->
      get_role_user(:project, project.id, :project_owner)

    # Check for lead
    lead = extract_lead(resource, context) ->
      get_role_user(:lead, lead.id, :lead_owner)

    # Fallback
    true ->
      []
  end
end

def resolve_team(resource, context) do
  case extract_project(resource, context) do
    nil -> []
    project ->
      RoleAssignment
      |> Ash.Query.filter(scope_type == :project and scope_id == ^project.id)
      |> Ash.Query.load(:user)
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.user)
      |> Enum.reject(&is_nil/1)
  end
end

# Helper to extract project from resource or context
defp extract_project(%Project{} = project, _context), do: project
defp extract_project(%Phase{project: project}, _context), do: project
defp extract_project(_, context), do: Map.get(context.data, :project)
```

## Backwards Compatibility

The new resolver system checks for `recipient_resolver` config first. If not configured, it falls back to the legacy MFA-based `audiences` configuration:

```elixir
# New (recommended)
config :ash_dispatch,
  recipient_resolver: MyApp.RecipientResolver

# Legacy (still supported)
config :ash_dispatch,
  audiences: [
    owner: {MyApp.Resolver, :owner, [:resource]},
    team: {MyApp.Resolver, :team, [:resource]}
  ]
```

## Complete Example

Here's a full resolver for a typical SaaS application:

```elixir
defmodule MyApp.RecipientResolver do
  @moduledoc """
  Recipient resolver for MyApp notifications.
  """

  use AshDispatch.RecipientResolver,
    user_resource: MyApp.Accounts.User

  require Ash.Query

  audiences do
    # Context-based
    audience :user, from_context: :user
    audience :assignee, from_context: [:user, :assignee]
    audience :customer_user, from_context: [:customer_user, :user]
    audience :participants, from_context: [:meeting, :participants], extract: :user

    # Query-based
    audience :admins, resolve: :resolve_admins

    # Custom resolvers
    audience :owner, resolve: :resolve_owner
    audience :team, resolve: :resolve_team

    # Composite
    audience :stakeholders, combine: [:owner, :team]

    # Non-user recipient
    audience :lead_contact, resolve: :resolve_lead_contact, raw: true
  end

  @impl true
  def to_recipient(%MyApp.Accounts.User{} = user) do
    %{
      id: user.id,
      email: to_string(user.email),
      display_name: user.full_name || user.first_name || to_string(user.email),
      first_name: user.first_name
    }
  end

  # ============ Custom Resolvers ============

  def resolve_owner(resource, context) do
    cond do
      project = extract_project(resource, context) ->
        get_role_user(:project, project.id, :project_owner)

      lead = extract_lead(resource, context) ->
        get_role_user(:lead, lead.id, :lead_owner)

      meeting = get_in_context(context, :meeting) ->
        case Map.get(meeting, :organizer) do
          nil -> []
          organizer -> [organizer]
        end

      true ->
        []
    end
  end

  def resolve_team(resource, context) do
    case extract_project(resource, context) do
      nil ->
        []

      project ->
        MyApp.Accounts.RoleAssignment
        |> Ash.Query.filter(
          scope_type == :project and scope_id == ^project.id and is_active == true
        )
        |> Ash.Query.load(user: [:full_name])
        |> Ash.read(authorize?: false)
        |> case do
          {:ok, assignments} ->
            Enum.map(assignments, & &1.user) |> Enum.reject(&is_nil/1)
          _ ->
            []
        end
    end
  end

  def resolve_admins(_resource, _context) do
    MyApp.Accounts.User
    |> Ash.Query.filter(role == :admin and is_active == true)
    |> Ash.read!(authorize?: false)
  end

  def resolve_lead_contact(resource, context) do
    case extract_lead(resource, context) do
      nil ->
        []

      lead when not is_nil(lead.contact_email) ->
        [%{
          id: lead.id,
          email: lead.contact_email,
          display_name: lead.contact_name || "there"
        }]

      _ ->
        []
    end
  end

  # ============ Private Helpers ============

  defp extract_project(%MyApp.Projects.Project{} = project, _), do: project
  defp extract_project(%MyApp.Projects.Phase{} = phase, _), do: ensure_loaded(phase, :project)
  defp extract_project(_, context), do: get_in_context(context, :project)

  defp extract_lead(%MyApp.Leads.Lead{} = lead, _), do: lead
  defp extract_lead(_, context), do: get_in_context(context, :lead)

  defp get_in_context(context, key) do
    context |> Map.get(:data, %{}) |> Map.get(key)
  end

  defp ensure_loaded(struct, field) do
    case Map.get(struct, field) do
      %Ash.NotLoaded{} ->
        case Ash.load(struct, [field], authorize?: false) do
          {:ok, loaded} -> Map.get(loaded, field)
          _ -> nil
        end
      value ->
        value
    end
  end

  defp get_role_user(scope_type, scope_id, function) do
    MyApp.Accounts.RoleAssignment
    |> Ash.Query.for_read(:primary_for_function, %{
      scope_type: scope_type,
      scope_id: scope_id,
      function: function
    })
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, assignment} when not is_nil(assignment) ->
        case Ash.get(MyApp.Accounts.User, assignment.user_id, authorize?: false, load: [:full_name]) do
          {:ok, user} -> [user]
          _ -> []
        end
      _ ->
        []
    end
  end
end
```

## Testing

Test your resolver with unit tests:

```elixir
defmodule MyApp.RecipientResolverTest do
  use MyApp.DataCase

  alias MyApp.RecipientResolver

  describe "to_recipient/1" do
    test "formats user with full name" do
      user = insert(:user, email: "test@example.com", full_name: "John Doe")

      assert RecipientResolver.to_recipient(user) == %{
        id: user.id,
        email: "test@example.com",
        display_name: "John Doe",
        first_name: user.first_name
      }
    end
  end

  describe "resolve_owner/2" do
    test "returns project owner" do
      owner = insert(:user)
      project = insert(:project)
      insert(:role_assignment, user: owner, scope_type: :project, scope_id: project.id, function: :project_owner)

      context = %{data: %{project: project}}

      [resolved] = RecipientResolver.resolve_owner(project, context)
      assert resolved.id == owner.id
    end

    test "returns empty for project without owner" do
      project = insert(:project)
      context = %{data: %{project: project}}

      assert RecipientResolver.resolve_owner(project, context) == []
    end
  end
end
```

## Migration Guide

### From Legacy MFA Configuration

**Before (config.exs):**
```elixir
config :ash_dispatch,
  audiences: [
    owner: {MyApp.Resolver, :owner, [:resource]},
    team: {MyApp.Resolver, :team, [:resource]},
    admins: {MyApp.Resolver, :admins, [:resource]},
    assignee: {MyApp.Resolver, :assignee, [:context]}
  ]
```

**After (resolver module):**
```elixir
defmodule MyApp.RecipientResolver do
  use AshDispatch.RecipientResolver,
    user_resource: MyApp.Accounts.User

  audiences do
    audience :owner, resolve: :resolve_owner
    audience :team, resolve: :resolve_team
    audience :admins, resolve: :resolve_admins
    audience :assignee, from_context: [:user, :assignee]
  end

  # Move resolver functions here...
end
```

**Config update:**
```elixir
config :ash_dispatch,
  recipient_resolver: MyApp.RecipientResolver
```

## Best Practices

### 1. Use Appropriate Strategies

- **Simple context extraction:** Use `from_context`
- **Role/attribute queries:** Use `query`
- **Relationship traversal:** Use `path`
- **Complex business logic:** Use `resolve`
- **Combined audiences:** Use `combine`

### 2. Handle Missing Data Gracefully

```elixir
def resolve_owner(resource, context) do
  case extract_project(resource, context) do
    nil -> []  # Return empty list, not nil
    project -> get_owner(project)
  end
end
```

### 3. Keep Resolvers Fast

- Use `authorize?: false` for internal queries
- Preload necessary relationships
- Consider caching for expensive lookups

### 4. Document Your Audiences

```elixir
audiences do
  # The user who triggered the event
  audience :user, from_context: :user

  # Project owner via RoleAssignment (project_owner function)
  audience :owner, resolve: :resolve_owner

  # All team members assigned to the project
  audience :team, resolve: :resolve_team
end
```

## See Also

- [User Preferences](user-preferences.md) - Control which notifications users receive
- [DSL Reference](../dsls/DSL-AshDispatch-Resource.md) - Event configuration
