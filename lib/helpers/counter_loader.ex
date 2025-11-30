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

  alias AshDispatch.Config
  alias AshDispatch.Helpers.ResourceIntrospection

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
    Config.domains()
  end

  defp load_user(user_id) do
    user_module = Config.user_module()

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
    audiences_config = Config.audiences()

    # Check if audience is a bare atom in the list (e.g., :user)
    audience_config =
      if audience in audiences_config do
        # Bare atom = all users in this audience
        []
      else
        Keyword.get(audiences_config, audience, [])
      end

    # Extract the actual filter from the config using consolidated helper
    # New format: [:user, admin: true] -> extract [admin: true]
    # Old format: [admin: true] -> use as-is
    audience_filter = ResourceIntrospection.extract_audience_filter(audience_config)

    # Empty filter means "all users" (e.g., :user audience)
    if audience_filter == [] do
      true
    else
      # Use Ash query engine to check if user matches the filter
      # This works with any Ash filter expression, not just simple equality
      user_module = Config.user_module()

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

  # Generic counter query execution
  # - authorize?: true → use Ash authorization with actor
  # - authorize?: false → bypass authorization (system-wide totals)
  # - scope: expr(...) → apply Ash expression with actor context
  # - user_id_path: [...] → legacy sugar for simple scoping
  # - aggregate: :name → use Ash aggregate instead of query_filter
  defp execute_counter_query(counter, user_id, actor) do
    # Use specified resource or fall back to the resource that defined the counter
    resource = counter.resource

    # Determine authorization settings
    # authorize?: false bypasses authorization, others use actor
    authorize? = Map.get(counter, :authorize?, true)

    # When authorize? is false, pass nil as actor for query execution
    # But keep the original actor for scope expression evaluation
    query_actor = if authorize?, do: actor, else: nil

    # Check if using aggregate instead of query_filter
    if counter.aggregate do
      execute_aggregate_counter(resource, counter.aggregate, query_actor, authorize?)
    else
      # Pass both actor (for scope) and query_actor (for authorization)
      execute_query_filter_counter(counter, user_id, actor, query_actor, authorize?)
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
  #
  # Scoping logic (priority order):
  # 1. scope: expr(...) → apply Ash expression with actor context
  # 2. user_id_path: [...] → legacy sugar for simple scoping
  # 3. No scoping → count all matching records (authorize? still applies)
  #
  # Parameters:
  # - counter: The counter struct from DSL
  # - user_id: The user ID for user_id_path filtering
  # - actor: The actual actor (for scope expression evaluation)
  # - query_actor: The actor for Ash query (nil when authorize? is false)
  # - authorize?: Whether to use Ash authorization
  #
  # Note: audience is about WHO receives the broadcast, not about query scoping.
  # A :partner audience might still want user-scoped data if scope/user_id_path is set.
  defp execute_query_filter_counter(counter, user_id, actor, query_actor, authorize?) do
    resource = counter.resource
    scope = Map.get(counter, :scope)

    query =
      resource
      |> Ash.Query.new()
      |> Ash.Query.filter(^counter.query_filter)

    # Use consolidated helper for user_id_path resolution
    user_id_path =
      ResourceIntrospection.resolve_user_id_path_for_scoping(resource,
        authorize?: authorize?,
        scope: scope,
        user_id_path: counter.user_id_path,
        audience: counter.audience
      )

    query =
      cond do
        # Explicit scope expression takes precedence
        # Use the actual actor (not query_actor) for scope evaluation
        scope && actor ->
          apply_scope_expression(query, scope, actor)

        # Legacy user_id_path support
        user_id && user_id_path && !counter.filter_by_record ->
          user_filter = ResourceIntrospection.build_user_filter(user_id_path, user_id)
          Ash.Query.filter(query, ^user_filter)

        # Special case: filter_by_record with nested user_id_path
        user_id && user_id_path && counter.filter_by_record && length(user_id_path) > 1 ->
          user_filter = ResourceIntrospection.build_user_filter(user_id_path, user_id)
          Ash.Query.filter(query, ^user_filter)

        # No scoping (global counter or filter_by_record handles it)
        true ->
          query
      end

    Ash.count!(query, actor: query_actor, authorize?: authorize?)
  end

  # Apply scope expression with actor context.
  #
  # Scope expressions can use ^actor(:field) templates to reference
  # the actor's attributes. For example:
  #   scope: expr(user_id == ^actor(:id))
  #   scope: expr(region == ^actor(:region))
  #   scope: expr(assigned_support.team_id == ^actor(:team_id))
  defp apply_scope_expression(query, scope_expr, actor) do
    query
    |> Ash.Query.set_context(%{actor: actor})
    |> Ash.Query.filter(^scope_expr)
  end
end
