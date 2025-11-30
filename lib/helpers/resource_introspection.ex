defmodule AshDispatch.Helpers.ResourceIntrospection do
  @moduledoc """
  Helpers for introspecting Ash resources to derive configuration automatically.

  These helpers enable zero-configuration setups by examining resource
  relationships and attributes to infer settings that would otherwise
  require explicit configuration.

  ## Usage

      alias AshDispatch.Helpers.ResourceIntrospection

      # Find the user_id field on a resource
      ResourceIntrospection.derive_user_id_path(MyApp.Orders.Order)
      #=> [:user_id]

      # Find all user relationships
      ResourceIntrospection.find_user_relationships(MyApp.Tickets.Ticket)
      #=> [%{name: :user, source_attribute: :user_id}, %{name: :assigned_to, source_attribute: :assigned_to_id}]

  ## Ambiguity Handling

  When a resource has multiple relationships to the user module, these helpers
  return `nil` and log a warning. In such cases, explicit configuration is required.
  """

  alias AshDispatch.Config

  require Logger

  @doc """
  Derives the user_id_path by introspecting the resource's relationships.

  Finds the `belongs_to` relationship that points to the configured `user_module`
  and returns its `source_attribute` as a single-element list (e.g., `[:user_id]`).

  ## Return Values

  - `[:field_name]` - Single unambiguous user relationship found
  - `nil` - No user relationship, multiple relationships (ambiguous), or error

  ## Examples

      # Single user relationship
      derive_user_id_path(MyApp.Notifications.Notification)
      #=> [:user_id]

      # Multiple relationships (logs warning)
      derive_user_id_path(MyApp.Tickets.Ticket)  # has :user and :assigned_admin
      #=> nil

      # No user relationship
      derive_user_id_path(MyApp.Settings.Config)
      #=> nil

  ## Configuration

  Requires `:user_module` to be configured:

      config :ash_dispatch,
        user_module: MyApp.Accounts.User
  """
  @spec derive_user_id_path(module()) :: [atom()] | nil
  def derive_user_id_path(resource) do
    derive_user_id_path(resource, nil)
  end

  @doc """
  Derives user_id_path with audience-aware disambiguation.

  When a resource has multiple user relationships, this function can auto-select
  the correct one if the audience name matches a relationship name.

  ## Examples

      # Ticket has :user, :started_by, :resolved_by, :closed_by
      derive_user_id_path(Ticket, :user)
      #=> [:user_id]  # Auto-picks :user because audience matches

      derive_user_id_path(Ticket, :resolved_by)
      #=> [:resolved_by_id]  # Auto-picks :resolved_by

      derive_user_id_path(Ticket, :admin)
      #=> nil  # No match, warns with guidance

  ## Parameters

  - `resource` - The Ash resource module
  - `audience` - The audience atom (e.g., `:user`, `:admin`). Pass `nil` for legacy behavior.

  ## Return Values

  - `[:field_name]` - Relationship found (single or matched by audience)
  - `nil` - No relationship, ambiguous without match, or error
  """
  @spec derive_user_id_path(module(), atom() | nil) :: [atom()] | nil
  def derive_user_id_path(resource, audience) do
    case find_user_relationships(resource) do
      [] ->
        nil

      [rel] ->
        [rel.source_attribute]

      multiple ->
        # Try to disambiguate using audience name
        matching_rel = Enum.find(multiple, fn rel -> rel.name == audience end)

        if matching_rel do
          # Audience matches a relationship name - use it
          [matching_rel.source_attribute]
        else
          # No match - warn with helpful guidance
          rel_names = Enum.map(multiple, & &1.name)

          Logger.warning("""
          [ResourceIntrospection] Ambiguous user relationships on #{inspect(resource)}.
          Found multiple belongs_to relationships to user module: #{inspect(rel_names)}

          To fix, add explicit user_id_path in your counter DSL:

              counter :my_counter,
                audience: :user,
                user_id_path: [:user_id]  # or [:#{Enum.at(rel_names, 1)}_id], etc.
          """)

          nil
        end
    end
  rescue
    error ->
      Logger.warning(
        "[ResourceIntrospection] Failed to derive user_id_path from #{inspect(resource)}: #{inspect(error)}"
      )

      nil
  end

  @doc """
  Finds all `belongs_to` relationships that point to the configured user module.

  Returns a list of relationship structs with their metadata.

  ## Examples

      find_user_relationships(MyApp.Tickets.Ticket)
      #=> [
      #     %{name: :user, source_attribute: :user_id, type: :belongs_to},
      #     %{name: :assigned_to, source_attribute: :assigned_to_id, type: :belongs_to}
      #   ]

      find_user_relationships(MyApp.Settings.Config)
      #=> []
  """
  @spec find_user_relationships(module()) :: [map()]
  def find_user_relationships(resource) do
    user_module = Config.user_module()

    if is_nil(user_module) do
      []
    else
      resource
      |> Ash.Resource.Info.relationships()
      |> Enum.filter(fn rel ->
        rel.type == :belongs_to && rel.destination == user_module
      end)
      |> Enum.map(fn rel ->
        %{
          name: rel.name,
          source_attribute: rel.source_attribute,
          type: rel.type,
          destination: rel.destination
        }
      end)
    end
  rescue
    _error ->
      []
  end

  @doc """
  Resolves the user_id_path for counter scoping using the three-layer control model.

  This function consolidates the logic for determining how to scope counter queries:

  1. **authorize?: false** → No user scoping (system-wide counter)
  2. **scope provided** → Scope expression takes precedence
  3. **explicit user_id_path** → Use the configured path
  4. **auto-derive** → Introspect resource relationships

  ## Parameters

  - `resource` - The Ash resource module
  - `opts` - Options keyword list with:
    - `:authorize?` - Whether to use Ash policies (default: true)
    - `:scope` - Explicit scope expression (Ash.Expr)
    - `:user_id_path` - Explicit path to user_id field
    - `:audience` - Audience atom for relationship disambiguation

  ## Examples

      # Admin counter - no scoping
      resolve_user_id_path_for_scoping(Order, authorize?: false, audience: :admin)
      #=> nil

      # User counter with explicit path
      resolve_user_id_path_for_scoping(Ticket, authorize?: true, user_id_path: [:user_id])
      #=> [:user_id]

      # Auto-derive from relationship
      resolve_user_id_path_for_scoping(Order, authorize?: true, audience: :user)
      #=> [:user_id]  # if Order has belongs_to :user
  """
  @spec resolve_user_id_path_for_scoping(module(), keyword()) :: [atom()] | nil
  def resolve_user_id_path_for_scoping(resource, opts) do
    authorize? = Keyword.get(opts, :authorize?, true)
    scope = Keyword.get(opts, :scope)
    explicit_path = Keyword.get(opts, :user_id_path)
    audience = Keyword.get(opts, :audience)

    cond do
      # Layer 1: authorize?: false means no user scoping (system-wide counter)
      not authorize? ->
        nil

      # Layer 2: Explicit scope expression takes precedence
      scope ->
        nil

      # Layer 3: Use explicit or derived user_id_path
      true ->
        explicit_path || derive_user_id_path(resource, audience)
    end
  end

  @doc """
  Checks if a resource has any relationship to the user module.

  ## Examples

      has_user_relationship?(MyApp.Orders.Order)
      #=> true

      has_user_relationship?(MyApp.Settings.Config)
      #=> false
  """
  @spec has_user_relationship?(module()) :: boolean()
  def has_user_relationship?(resource) do
    find_user_relationships(resource) != []
  end

  @doc """
  Builds a filter expression for user_id based on a path.

  Converts a path like `[:user_id]` or `[:cart, :user_id]` into an Ash-compatible
  filter keyword list that can be used with `Ash.Query.filter/2`.

  ## Examples

      # Simple path
      build_user_filter([:user_id], "user-123")
      #=> [user_id: "user-123"]

      # Nested path (through relationship)
      build_user_filter([:cart, :user_id], "user-123")
      #=> [cart: [user_id: "user-123"]]

      # Deeply nested
      build_user_filter([:order, :cart, :user_id], "user-123")
      #=> [order: [cart: [user_id: "user-123"]]]
  """
  @spec build_user_filter([atom()], String.t()) :: keyword()
  def build_user_filter([field], user_id) do
    [{field, user_id}]
  end

  def build_user_filter([relationship | rest], user_id) do
    nested_filter = build_user_filter(rest, user_id)
    [{relationship, nested_filter}]
  end

  @doc """
  Determines if an audience is relationship-based or filter-based.

  This distinction is important for counter recipient resolution:
  - **Relationship-based** (bare atom in config): Extract recipient from the record itself
  - **Filter-based** (tuple in config): Query all users matching the filter

  ## Audience Config Pattern

  The audience configuration in `config :ash_dispatch, :audiences` uses this convention:

      audiences: [
        :user,                                # Bare atom = relationship-based
        {:admin, [:user, {:admin, true}]},    # Tuple = filter-based
        {:partner, [:partner]}                # Tuple with relationship path
      ]

  ## Examples

      is_relationship_audience?(:user)
      #=> true  (extract from record's :user relationship)

      is_relationship_audience?(:admin)
      #=> false (query all users where admin: true)

      is_relationship_audience?(:custom)
      #=> true  (not in config, assume relationship-based for backward compat)

  ## Use Cases

  For counters:
  - Relationship-based audience → broadcast to record owner only
  - Filter-based audience → broadcast to ALL matching users

  For events:
  - Both use the same resolution, but relationship-based extracts from context
  """
  @spec is_relationship_audience?(atom()) :: boolean()
  def is_relationship_audience?(audience_name) do
    audiences_config = Config.audiences()

    cond do
      # Bare atom in config list = relationship-based
      Enum.member?(audiences_config, audience_name) -> true
      # Tuple/keyword entry = filter-based
      Keyword.has_key?(audiences_config, audience_name) -> false
      # Not in config - assume relationship-based (backward compatibility)
      # This allows custom audiences to work without explicit config
      true -> true
    end
  end

  @doc """
  Returns the relationship name for a relationship-based audience.

  For bare atom audiences, the audience name IS the relationship name.
  For filter-based audiences, extracts the first atom from the config path.

  ## Examples

      get_audience_relationship(:user)
      #=> :user

      get_audience_relationship(:admin)  # config: {:admin, [:user, {:admin, true}]}
      #=> :user  (follows :user relationship, then filters)

      get_audience_relationship(:partner)  # config: {:partner, [:partner]}
      #=> :partner
  """
  @spec get_audience_relationship(atom()) :: atom() | nil
  def get_audience_relationship(audience_name) do
    audiences_config = Config.audiences()

    cond do
      # Bare atom = relationship name is the audience name
      Enum.member?(audiences_config, audience_name) ->
        audience_name

      # Tuple format: {:admin, [:user, {:admin, true}]}
      # First atom in the list is the relationship
      true ->
        case Keyword.get(audiences_config, audience_name) do
          [rel | _rest] when is_atom(rel) -> rel
          _ -> nil
        end
    end
  end

  @doc """
  Parses an audience config list into relationship path and filter components.

  This is the unified parsing logic used by both counter and event resolution.

  ## Examples

      # New format with relationship path
      parse_audience_config([:user, {:admin, true}])
      #=> {[:user], [admin: true]}

      # Relationship chain (no filter)
      parse_audience_config([:user, :associated_seller])
      #=> {[:user, :associated_seller], []}

      # Legacy format (filter only)
      parse_audience_config([{:admin, true}])
      #=> {[], [admin: true]}

      # Empty config
      parse_audience_config([])
      #=> {[], []}

  ## Return Value

  Returns a tuple `{relationship_path, filter}` where:
  - `relationship_path` is a list of atoms representing relationships to follow
  - `filter` is a keyword list of filter conditions
  """
  @spec parse_audience_config(list()) :: {[atom()], keyword()}
  def parse_audience_config(config) when is_list(config) do
    # Split into relationship path (bare atoms) and filter (keyword pairs)
    Enum.split_while(config, fn
      item when is_atom(item) -> true
      {_key, _value} -> false
    end)
  end

  def parse_audience_config(_), do: {[], []}

  @doc """
  Extracts just the filter from an audience config.

  Convenience function that returns only the filter portion, discarding
  the relationship path. Useful for checking if a user matches an audience.

  ## Examples

      extract_audience_filter([:user, {:admin, true}])
      #=> [admin: true]

      extract_audience_filter([:user])
      #=> []
  """
  @spec extract_audience_filter(list()) :: keyword()
  def extract_audience_filter(config) do
    {_path, filter} = parse_audience_config(config)
    filter
  end
end
