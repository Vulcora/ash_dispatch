defmodule AshDispatch.Helpers.CounterLoader do
  @moduledoc """
  Helper for loading initial counter values when users connect.

  This module automatically discovers counter definitions from your Ash resources
  and loads their current values. No manual configuration required!

  ## How It Works

  1. Discovers all resources using `AshDispatch.Resource` extension
  2. Reads counter definitions from the `counters` DSL section
  3. Executes queries based on DSL configuration
  4. Returns a map of counter names to their current values

  ## Usage in Phoenix Channels

      defmodule MyAppWeb.UserChannel do
        use Phoenix.Channel

        alias AshDispatch.Helpers.CounterLoader

        def join("user:" <> user_id, _params, socket) do
          # Load initial counter values for this user
          counters = CounterLoader.load_counters_for_user(
            user_id,
            is_admin: user_is_admin?(user_id)
          )

          {:ok, %{counters: counters}, assign(socket, :user_id, user_id)}
        end

        # Listen for counter broadcasts
        def handle_info({:counter_update, counter_name, count, metadata}, socket) do
          push(socket, "counter_update", %{
            counter: counter_name,
            count: count,
            invalidate_queries: metadata.invalidate_queries
          })

          {:noreply, socket}
        end
      end

  ## Frontend Integration

      // React/TypeScript example
      channel.on("counter_update", (payload) => {
        // Update counter in state
        setCounters(prev => ({
          ...prev,
          [payload.counter]: payload.count
        }));

        // Invalidate related queries
        payload.invalidate_queries.forEach(queryKey => {
          queryClient.invalidateQueries([queryKey]);
        });
      });

  ## Counter Definition

  Counters are defined in resource DSL:

      defmodule MyApp.Orders.ProductOrder do
        use Ash.Resource,
          extensions: [AshDispatch.Resource]

        counters do
          counter :pending_orders do
            trigger_on [:create, :complete]
            counter_name :pending_orders
            query_filter [status: :pending]
            audience :user
            invalidates ["orders"]
          end
        end
      end

  The CounterLoader automatically discovers and uses these definitions!
  """

  require Logger
  require Ash.Query

  @doc """
  Load all counter values for a specific user.

  Automatically discovers counter definitions from resources and executes
  queries based on user's audiences (derived from configured recipient filters).

  Returns a map of counter names to their current values.

  ## Options

  - `:domains` - List of Ash domains to search for resources (defaults to all configured domains)

  ## Examples

      # Load counters for any user (automatically determines audiences)
      CounterLoader.load_counters_for_user("user-123")
      #=> %{pending_orders: 5, cart_items: 3}

      # Admin user automatically gets admin counters
      CounterLoader.load_counters_for_user("admin-456")
      #=> %{pending_orders: 12, admin_pending_reseller_requests: 3}

      # Load from specific domains only
      CounterLoader.load_counters_for_user("user-123", domains: [MyApp.Orders])
      #=> %{pending_orders: 5}
  """
  def load_counters_for_user(user_id, opts \\ []) do
    domains = Keyword.get(opts, :domains, get_all_domains())

    # Load user record to check audiences
    user = load_user(user_id)

    # Discover all counter definitions from resources
    counter_definitions = discover_counter_definitions(domains)

    # Filter counters based on user's audiences (using configured filters)
    relevant_counters =
      Enum.filter(counter_definitions, fn counter ->
        user_matches_audience?(user, counter.audience)
      end)

    # Execute queries and build counter map
    Enum.reduce(relevant_counters, %{}, fn counter, acc ->
      count = execute_counter_query(counter, user_id, user)
      # Use counter_name if set, otherwise fall back to the DSL name
      name = counter.counter_name || counter.name
      Map.put(acc, name, count)
    end)
  end

  @doc """
  Load counters for admin users only.

  Discovers all counters with `:admin` audience and executes their queries.

  ## Examples

      CounterLoader.load_admin_counters()
      #=> %{admin_pending_reseller_requests: 3, admin_pending_orders: 12}
  """
  def load_admin_counters(opts \\ []) do
    domains = Keyword.get(opts, :domains, get_all_domains())

    # Discover all counter definitions
    counter_definitions = discover_counter_definitions(domains)

    # Filter admin-only counters
    admin_counters =
      Enum.filter(counter_definitions, fn counter ->
        counter.audience == :admin
      end)

    # Execute queries (no user_id needed for admin counters)
    Enum.reduce(admin_counters, %{}, fn counter, acc ->
      count = execute_counter_query(counter, nil)
      # Use counter_name if set, otherwise fall back to the DSL name
      name = counter.counter_name || counter.name
      Map.put(acc, name, count)
    end)
  end

  # Private helpers

  defp discover_counter_definitions(domains) do
    domains
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.filter(&uses_ash_dispatch?/1)
    |> Enum.flat_map(&extract_counters/1)
  end

  defp uses_ash_dispatch?(resource) do
    AshDispatch.Resource in Spark.extensions(resource)
  end

  defp extract_counters(resource) do
    case Spark.Dsl.Extension.get_entities(resource, [:counters]) do
      [] ->
        []

      counters ->
        # Add resource to each counter for query execution
        Enum.map(counters, fn counter ->
          %{counter | resource: counter.resource || resource}
        end)
    end
  rescue
    error ->
      Logger.warning(
        "[CounterLoader] Failed to extract counters from #{inspect(resource)}: #{inspect(error)}"
      )

      []
  end

  defp get_all_domains do
    Application.get_env(:ash_dispatch, :domains, [])
  end

  defp load_user(user_id) do
    user_module = Application.get_env(:ash_dispatch, :user_module)

    if user_module do
      user_module
      |> Ash.Query.new()
      |> Ash.Query.filter(id == ^user_id)
      |> Ash.read_one!(authorize?: false)
    else
      Logger.warning("[CounterLoader] No user_module configured")
      nil
    end
  rescue
    error ->
      Logger.error("[CounterLoader] Failed to load user #{user_id}: #{inspect(error)}")
      nil
  end

  # Check if user matches the audience using configured recipient filters
  # Uses Ash query engine to properly evaluate filter expressions
  defp user_matches_audience?(nil, _audience), do: false

  defp user_matches_audience?(user, audience) do
    # Get the filter for this audience from config
    audiences_config = Application.get_env(:ash_dispatch, :audiences, [])

    # Check if audience is a bare atom in the list (e.g., :user)
    audience_config =
      if audience in audiences_config do
        # Bare atom = all users in this audience
        []
      else
        Keyword.get(audiences_config, audience, [])
      end

    # Extract the actual filter from the config
    # New format: [:user, admin: true] -> extract [admin: true]
    # Old format: [admin: true] -> use as-is
    audience_filter = extract_filter_from_config(audience_config)

    # Empty filter means "all users" (e.g., :user audience)
    if audience_filter == [] do
      true
    else
      # Use Ash query engine to check if user matches the filter
      # This works with any Ash filter expression, not just simple equality
      user_module = Application.get_env(:ash_dispatch, :user_module)

      user_module
      |> Ash.Query.new()
      |> Ash.Query.filter(id == ^user.id)
      |> Ash.Query.filter(^audience_filter)
      |> Ash.exists?(authorize?: false)
    end
  rescue
    error ->
      Logger.error("[CounterLoader] Failed to check user audience #{audience}: #{inspect(error)}")

      false
  end

  # Extract the actual filter from audience config
  # Handles both new format [:user, admin: true] and old format [admin: true]
  defp extract_filter_from_config(config) when is_list(config) do
    # Split into relationship path (bare atoms) and filter (keyword pairs)
    {_relationship_path, filter} =
      Enum.split_while(config, fn
        item when is_atom(item) -> true
        {_key, _value} -> false
      end)

    filter
  end

  defp extract_filter_from_config(_), do: []

  # Generic counter query execution
  # - For :user audience: scope query to specific user_id
  # - For all other audiences (:admin, :partner, :system, etc): execute global query
  # - For global? counters: bypass authorization
  # - For aggregate counters: use Ash aggregate instead of query_filter
  defp execute_counter_query(counter, user_id, actor \\ nil) do
    # Use specified resource or fall back to the resource that defined the counter
    resource = counter.resource

    # Determine authorization settings
    # global? counters bypass authorization, others use actor
    is_global = Map.get(counter, :global?, false)
    authorize? = not is_global
    query_actor = if is_global, do: nil, else: actor

    # Check if using aggregate instead of query_filter
    if counter.aggregate do
      execute_aggregate_counter(resource, counter.aggregate, query_actor, authorize?)
    else
      execute_query_filter_counter(counter, user_id, query_actor, authorize?)
    end
  rescue
    error ->
      counter_name = counter.counter_name || counter.name

      Logger.error(
        "[CounterLoader] Failed to execute counter query for #{counter_name}: #{inspect(error)}"
      )

      0
  end

  # Execute counter using Ash aggregate
  defp execute_aggregate_counter(resource, aggregate_name, actor, authorize?) do
    result =
      resource
      |> Ash.Query.new()
      |> Ash.Query.load(aggregate_name)
      |> Ash.read_one(actor: actor, authorize?: authorize?)

    case result do
      {:ok, nil} -> 0
      {:ok, record} -> Map.get(record, aggregate_name, 0)
      {:error, _} -> 0
    end
  end

  # Execute counter using query_filter
  defp execute_query_filter_counter(counter, user_id, actor, authorize?) do
    resource = counter.resource

    query =
      resource
      |> Ash.Query.new()
      |> Ash.Query.filter(^counter.query_filter)

    # Only scope to user_id if audience is :user and not global
    # Skip if filter_by_record is set - these counters need record context and should use
    # a user_id_path that goes through relationships (e.g., [:cart, :user_id] for CartItem)
    query =
      if counter.audience == :user && user_id && not Map.get(counter, :global?, false) do
        # If filter_by_record is set, the counter is designed for action context
        # and the user_id_path may not work for initial loading
        # Skip user filter if filter_by_record is set - will be handled differently
        if counter.filter_by_record do
          # For counters with filter_by_record, we need to use the relationship path
          # to find user's items. Use user_id_path if it goes through relationships.
          user_id_path = counter.user_id_path || [:user_id]

          # Only apply if path goes through relationships (length > 1)
          # e.g., [:cart, :user_id] works, but [:user_id] alone doesn't for CartItem
          if length(user_id_path) > 1 do
            user_filter = build_user_filter(user_id_path, user_id)
            Ash.Query.filter(query, ^user_filter)
          else
            # Skip this counter - can't properly scope without record context
            # Return empty query that will return 0
            Ash.Query.filter(query, false)
          end
        else
          # Standard case: use user_id_path directly
          user_id_path = counter.user_id_path || [:user_id]
          user_filter = build_user_filter(user_id_path, user_id)
          Ash.Query.filter(query, ^user_filter)
        end
      else
        query
      end

    Ash.count!(query, actor: actor, authorize?: authorize?)
  end

  # Build a filter expression for user_id based on the path
  defp build_user_filter([field], user_id) do
    [{field, user_id}]
  end

  defp build_user_filter([relationship | rest], user_id) do
    # For nested paths like [:cart, :user_id], build nested filter
    nested_filter = build_user_filter(rest, user_id)
    [{relationship, nested_filter}]
  end
end
