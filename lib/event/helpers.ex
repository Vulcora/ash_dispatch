defmodule AshDispatch.Event.Helpers do
  @moduledoc """
  Helper functions for events that use Ash introspection to derive behavior.

  These helpers enable zero-configuration recipient resolution by:
  - Introspecting Ash resources to find user relationships
  - Querying configured User module for admins
  - Extracting users from context automatically

  ## Configuration Required

  In your application config:

      config :ash_dispatch,
        user_module: MyApp.Accounts.User,
        admin_filter: [super_admin: true]

  ## How It Works

  **For :admin audience:**
  - Queries user_module with admin_filter
  - Returns list of admin users

  **For :user audience:**
  - Extracts user from context using Ash introspection
  - Follows relationships defined in resources
  - No hardcoded patterns needed

  **For :system audience:**
  - Returns configured system recipients (if any)
  """

  require Logger
  require Ash.Query

  @doc """
  Resolves recipients for a channel based on its audience.

  Uses Ash introspection to automatically find and extract users.
  Supports both legacy hardcoded audiences and new filter-based config.

  ## Filter-Based Resolution (New)

  Configure filters per audience in config:

      config :ash_dispatch,
        recipient_filters: [
          audiences: [
            admin: [admin: true],
            user: [],
            support: [role: :support]
          ]
        ]

  Or override per-event in DSL:

      event :urgent,
        recipient_filter: [
          audiences: [admin: [admin: true, on_duty: true]]
        ]

  ## Examples

      # Admin audience - uses filter from config
      resolve_recipients_for_audience(context, %Channel{audience: :admin})
      # => [%{id: "1", email: "admin@example.com", display_name: "Admin"}]

      # User audience - extracts from context via Ash
      resolve_recipients_for_audience(context, %Channel{audience: :user})
      # => [%{id: "123", email: "user@example.com", display_name: "John"}]
  """
  def resolve_recipients_for_audience(context, channel, event_config \\ %{}) do
    audience = channel.audience

    # Get audience configuration - supports multiple formats:
    # - Atom: :user (extract from :user relationship)
    # - List: [admin: true] (query with filter)
    # - List with templates: [admin: true, region: {:resource, [:user, :region]}]
    # - Function: fn resource -> [admin: true, region: resource.user.region] end
    # - MFA: {Module, :function, [:resource]}
    audience_config = get_filter_for_audience(audience, event_config)

    case audience_config do
      # Atom = extract single recipient from named relationship
      relationship_name when is_atom(relationship_name) ->
        resolve_from_relationship(context, relationship_name)

      # Function (anonymous) = call with resource to get dynamic filter
      func when is_function(func, 1) ->
        resource = extract_primary_resource(context)
        dynamic_filter = func.(resource)
        resolve_by_filter(dynamic_filter, context)

      # MFA tuple = call module function to get dynamic filter
      {module, function, args} when is_atom(module) and is_atom(function) and is_list(args) ->
        resource = extract_primary_resource(context)
        # Replace :resource placeholder with actual resource
        resolved_args =
          Enum.map(args, fn
            :resource -> resource
            other -> other
          end)

        dynamic_filter = apply(module, function, resolved_args)
        resolve_by_filter(dynamic_filter, context)

      # Empty list = all users (query with no filter)
      [] ->
        resolve_by_filter([], context)

      # List with relationship path and filter = [:user, admin: true]
      # First bare atoms are the relationship path, rest is filter
      list when is_list(list) ->
        {relationship_path, filter} = parse_relationship_path_and_filter(list)

        if relationship_path == [] do
          # No relationship path, just a filter (legacy format)
          resolve_by_filter(filter, context)
        else
          # New format: follow relationships, then apply filter
          resolve_via_relationship_and_filter(context, relationship_path, filter)
        end

      # Not configured
      nil ->
        Logger.warning("No recipient configuration for audience: #{inspect(audience)}")
        []
    end
  end

  # Extract the primary resource from context.data (first non-nil value)
  defp extract_primary_resource(context) do
    case context.data do
      %{} = data ->
        # Get the first value from context.data
        data
        |> Map.values()
        |> Enum.find(&(!is_nil(&1)))

      _ ->
        nil
    end
  end

  # Get filter for an audience from event config or app config
  # Supports multiple formats:
  # - Bare atom: :user (auto-infer relationship from audience name)
  # - Explicit atom: user: :user or user: :created_by (extract from relationship)
  # - Filter list: admin: [admin: true] (query with filter)
  # - Template filter: admin: [admin: true, region: {:resource, [:user, :region]}]
  # - Function/MFA: {Module, :function, args} (dynamic filter generation)
  defp get_filter_for_audience(audience, event_config) do
    # 1. Check event-level override
    event_filters = Map.get(event_config, :recipient_filter, %{})

    # Handle both map and list formats
    event_audiences =
      case event_filters do
        list when is_list(list) -> Keyword.get(list, :audiences, [])
        map when is_map(map) -> Map.get(map, :audiences, %{})
        _ -> %{}
      end

    event_filter =
      case event_audiences do
        list when is_list(list) ->
          # Check for bare atom first (auto-inference)
          if audience in list do
            # Bare atom found - use audience name as relationship name
            audience
          else
            # Look for explicit config
            Keyword.get(list, audience)
          end

        map when is_map(map) ->
          Map.get(map, audience)

        _ ->
          nil
      end

    # 2. Fall back to app config
    app_audiences = Application.get_env(:ash_dispatch, :audiences, [])

    app_filter =
      if audience in app_audiences do
        # Bare atom in app config - auto-infer
        audience
      else
        Keyword.get(app_audiences, audience)
      end

    # Return event filter if present, otherwise app filter
    event_filter || app_filter
  end

  # Resolve template values in a filter (e.g., {:resource, [:user, :region]} -> "EU")
  defp resolve_filter_templates(filter, context) when is_list(filter) do
    Enum.map(filter, fn
      {key, {:resource, path}} ->
        # Extract value from resource in context
        value = extract_value_from_path(context.data, path)
        {key, value}

      {key, value} ->
        {key, value}
    end)
  end

  # Parse audience config list into relationship path and filter
  # Examples:
  #   [:user, admin: true] -> {[:user], [admin: true]}
  #   [:user, :associated_seller] -> {[:user, :associated_seller], []}
  #   [admin: true] -> {[], [admin: true]}
  defp parse_relationship_path_and_filter(list) do
    {relationship_path, filter} =
      Enum.split_while(list, fn
        item when is_atom(item) -> true
        {_key, _value} -> false
      end)

    {relationship_path, filter}
  end

  # Resolve recipients by following relationship path and applying filter
  # For [:user, admin: true] - extract :user from context, filter for admin: true
  # For [:user, :associated_seller] - follow relationship chain
  defp resolve_via_relationship_and_filter(context, relationship_path, filter) do
    user_module = Application.get_env(:ash_dispatch, :user_module)

    if is_nil(user_module) do
      Logger.warning("No :user_module configured, cannot resolve via relationship path")
      []
    else
      case relationship_path do
        # Single relationship + filter: [:user, admin: true]
        # Extract from relationship, then filter if needed
        [_rel] when filter != [] ->
          # For audiences like "admin", we want ALL users matching filter
          # The relationship path is just for clarity in config (e.g., [:user, admin: true])
          resolve_by_filter(filter, context)

        # Single relationship, no filter: [:user]
        # Just extract from relationship (same as bare atom)
        [rel] ->
          resolve_from_relationship(context, rel)

        # Relationship chain: [:user, :associated_seller]
        # Follow the chain to get final recipients
        chain ->
          resolve_relationship_chain(context, chain)
      end
    end
  end

  # Follow a chain of relationships to get recipients
  # e.g., [:user, :associated_seller] -> follow user.associated_seller
  defp resolve_relationship_chain(context, [first_rel | rest]) do
    # Get the first relationship value from context
    first_value =
      Enum.find_value(context.data, fn {_key, resource} ->
        if is_struct(resource) && Ash.Resource.Info.resource?(resource.__struct__) do
          Map.get(resource, first_rel)
        end
      end)

    if is_nil(first_value) do
      Logger.warning("Could not find relationship #{inspect(first_rel)} in context")
      []
    else
      # Follow the rest of the chain
      final_value = follow_relationship_chain(first_value, rest)

      case final_value do
        nil ->
          []

        value when is_list(value) ->
          # Return raw user structs - RecipientExtractor handles field extraction
          value

        value ->
          # Return raw user struct - RecipientExtractor handles field extraction
          [value]
      end
    end
  end

  # Follow remaining relationships in a chain
  defp follow_relationship_chain(value, []) do
    value
  end

  defp follow_relationship_chain(value, [rel | rest]) when is_struct(value) do
    next_value = Map.get(value, rel)

    if is_nil(next_value) do
      Logger.warning(
        "Could not follow relationship #{inspect(rel)} from #{inspect(value.__struct__)}"
      )

      nil
    else
      follow_relationship_chain(next_value, rest)
    end
  end

  defp follow_relationship_chain(values, chain) when is_list(values) do
    values
    |> Enum.flat_map(fn value ->
      case follow_relationship_chain(value, chain) do
        nil -> []
        result when is_list(result) -> result
        result -> [result]
      end
    end)
  end

  defp follow_relationship_chain(_, _), do: nil

  # Extract a value from context data using a path like [:user, :region]
  defp extract_value_from_path(data, path) when is_map(data) and is_list(path) do
    Enum.reduce(path, data, fn key, acc ->
      case acc do
        map when is_map(map) -> Map.get(map, key)
        struct when is_struct(struct) -> Map.get(struct, key)
        _ -> nil
      end
    end)
  end

  # Resolve recipients using an Ash Query filter
  defp resolve_by_filter(filter, context) do
    user_module = Application.get_env(:ash_dispatch, :user_module)

    if is_nil(user_module) do
      Logger.warning(
        "No :user_module configured in :ash_dispatch config, cannot resolve recipients"
      )

      []
    else
      # Resolve template placeholders if context is provided
      resolved_filter =
        if context && is_list(filter) do
          resolve_filter_templates(filter, context)
        else
          filter
        end

      # Query without select restriction - RecipientExtractor needs access to configured fields
      result =
        user_module
        |> Ash.Query.new()
        |> apply_filter(resolved_filter)
        |> Ash.read(authorize?: false)

      case result do
        {:ok, users} ->
          # Return raw user structs - RecipientExtractor handles field extraction
          users

        {:error, error} ->
          Logger.error(
            "Failed to query recipients with filter #{inspect(resolved_filter)}: #{inspect(error)}"
          )

          []
      end
    end
  end

  # Apply filter to query (handles both keyword list and map)
  defp apply_filter(query, filter) when filter == [] or filter == %{}, do: query
  defp apply_filter(query, filter) when is_list(filter), do: Ash.Query.filter_input(query, filter)

  defp apply_filter(query, filter) when is_map(filter) do
    filter_list = Enum.to_list(filter)
    Ash.Query.filter_input(query, filter_list)
  end

  # Resolve user from a named relationship in the context
  defp resolve_from_relationship(context, relationship_name) do
    user_module = Application.get_env(:ash_dispatch, :user_module)

    if is_nil(user_module) do
      Logger.warning(
        "No :user_module configured, cannot extract from relationship #{inspect(relationship_name)}"
      )

      []
    else
      # First check if context.data has a direct key matching relationship_name that is already a user
      # This handles cases like %{user: user} where the user is passed directly
      direct_user =
        case Map.get(context.data, relationship_name) do
          value when is_struct(value) and value.__struct__ == user_module ->
            value

          _ ->
            nil
        end

      # If not found directly, search for the relationship on resources in context.data
      user =
        direct_user ||
          Enum.find_value(context.data, fn {_key, resource} ->
            # Only process Ash resources
            if is_struct(resource) && Ash.Resource.Info.resource?(resource.__struct__) do
              # Try to get the value from the specified relationship
              value = Map.get(resource, relationship_name)

              # Check if it's the user module
              if is_struct(value) && value.__struct__ == user_module do
                value
              end
            end
          end)

      case user do
        nil ->
          Logger.warning("""
          Could not find relationship #{inspect(relationship_name)} in context data.
          Make sure the relationship is loaded via 'load: [#{inspect(relationship_name)}]' in your event config.
          """)

          []

        user ->
          # Return raw user struct - RecipientExtractor handles field extraction
          [user]
      end
    end
  end

  @doc """
  Evaluates an Ash filter expression against a user.

  Uses the Ash query engine to properly evaluate filter expressions,
  supporting all Ash filter syntax (nested fields, temporal expressions, etc.).

  ## Examples

      # Simple filter
      evaluate_user_filter(user, [confirmed_at: nil])
      #=> true/false

      # Complex filter
      evaluate_user_filter(user, [admin: true, archived: false])
      #=> true/false

  Returns true if user matches the filter, false otherwise.
  """
  def evaluate_user_filter(nil, _filter), do: false

  def evaluate_user_filter(_user, filter) when filter == [] or filter == %{} do
    # Empty filter means "all users"
    true
  end

  def evaluate_user_filter(user, filter) do
    user_module = Application.get_env(:ash_dispatch, :user_module)

    if is_nil(user_module) do
      Logger.warning("[Event.Helpers] No :user_module configured, cannot evaluate filter")
      false
    else
      user_id = user.id

      # Use Ash query engine to check if user matches the filter
      # This works with any Ash filter expression, not just simple equality
      query =
        user_module
        |> Ash.Query.new()
        |> Ash.Query.filter(id == ^user_id)

      # Apply the provided filter
      query = apply_filter(query, filter)

      Ash.exists?(query, authorize?: false)
    end
  rescue
    error ->
      Logger.error(
        "[Event.Helpers] Failed to evaluate filter #{inspect(filter)} for user: #{inspect(error)}"
      )

      false
  end

  @doc """
  Extracts the target user (recipient) from context and channel.

  Used by should_send?/2 to determine the recipient for filter evaluation.

  Returns the user struct if found, nil otherwise.
  """
  def extract_target_user(context, _channel) do
    # Try to extract user from :user relationship in context
    # Returns nil if no relationship exists or if audience uses filter-based resolution
    case resolve_from_relationship(context, :user) do
      [user | _] -> user
      [] -> nil
    end
  end
end
