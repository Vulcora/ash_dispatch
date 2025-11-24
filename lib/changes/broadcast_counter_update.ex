defmodule AshDispatch.Changes.BroadcastCounterUpdate do
  @moduledoc """
  Broadcasts real-time counter updates for actions that don't dispatch events.

  This change module provides direct counter broadcasting for actions that need
  real-time UI updates but don't require full notification workflows.

  ## When to Use This Pattern

  Use `BroadcastCounterUpdate` for:
  - **Actions without events**: Cart add/remove, preference updates, mark as read, etc.
  - **Real-time counters only**: No email or in-app notification needed
  - **Simple state updates**: User adds item, counter updates immediately

  ## When to Use Event-Based Pattern Instead

  Use event `counters/2` callback for:
  - **Actions that dispatch events**: Order creation, ticket updates, etc.
  - **Notification workflows**: In-app + email delivery
  - **Multi-channel communication**: User and admin notifications

  ## Configuration

  The counter system requires two configured modules:

      config :ash_dispatch,
        counter_registry: MyApp.CounterRegistry,
        counter_broadcaster: MyApp.CounterBroadcaster

  See `AshDispatch.Behaviours.CounterRegistry` and `AshDispatch.Behaviours.CounterBroadcaster`
  for implementation details.

  ## Usage

  ### Simple User Counter

      # In resource action (e.g., Cart.add_item)
      change {AshDispatch.Changes.BroadcastCounterUpdate, counter: :cart_items}

  ### Admin-Only Counter

      # Broadcast to all admins instead of specific user
      change {AshDispatch.Changes.BroadcastCounterUpdate,
        counter: :pending_orders,
        broadcast_to: :all_admins
      }

  ### Custom User ID Field

      # If the user_id is stored in a different field
      change {AshDispatch.Changes.BroadcastCounterUpdate,
        counter: :cart_items,
        user_id_field: :owner_id
      }

  ## Event-Based Pattern (for actions with events)

  For actions that dispatch events, declare counters in the event module:

      # In event module (lib/my_app/events/orders/created.ex)
      defmodule MyApp.Events.Orders.Created do
        use AshDispatch.Event

        @impl true
        def counters(_context, %Channel{transport: :in_app, audience: :user}) do
          [:pending_orders, :cart_items]
        end

        def counters(_context, %Channel{transport: :in_app, audience: :admin}) do
          [:admin_pending_orders]
        end

        def counters(_context, _channel), do: []
      end

  ## Options

  - `:counter_name` (required) - Counter name to broadcast
  - `:audience` (required) - Audience type (`:user`, `:admin`, or `:system`)
  - `:invalidates` (optional) - List of query keys to invalidate
  - `:user_id_field` (optional) - Field containing user ID (defaults to `:user_id`)

  ## Examples

      # User counter - broadcasts to specific user
      change {BroadcastCounterUpdate,
        counter_name: :pending_orders,
        audience: :user}

      # Admin counter - broadcasts to all admins
      change {BroadcastCounterUpdate,
        counter_name: :admin_pending_orders,
        audience: :admin,
        invalidates: ["admin_orders"]}

  ## How It Works

  The broadcaster implementation (configured via `:counter_broadcaster`) handles:
  - Query execution (how to count items)
  - Audience scoping (user-specific vs total counts)
  - Broadcasting to connected clients

  This change just declares WHAT to broadcast and to WHOM.
  """

  use Ash.Resource.Change

  require Ash.Query
  require Logger

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, result ->
      broadcast_counter(result, opts)
      {:ok, result}
    end)
  end

  defp broadcast_counter(record, opts) do
    counter_name = Keyword.fetch!(opts, :counter_name)
    resource = Keyword.fetch!(opts, :resource)
    query_filter = Keyword.fetch!(opts, :query_filter)
    audience = Keyword.fetch!(opts, :audience)
    invalidates = Keyword.get(opts, :invalidates, [])
    filter_by_record = Keyword.get(opts, :filter_by_record)

    Logger.debug("[BroadcastCounterUpdate] Starting broadcast for #{counter_name}, audience: #{audience}")

    # Resolve recipients using unified system (same as events)
    recipients = resolve_recipients_for_counter(record, audience, opts)
    Logger.debug("[BroadcastCounterUpdate] Resolved #{length(recipients)} recipients")

    # For each recipient, execute query and broadcast
    Enum.each(recipients, fn recipient ->
      # Determine if query should be user-scoped
      user_scoped? = audience == :user

      # Execute count query
      count =
        try do
          if user_scoped? do
            # User-scoped: count items for this specific user
            query =
              resource
              |> Ash.Query.new()

            # Apply static filter only if not empty/nil
            query = apply_query_filter(query, query_filter)

            # Apply user_id filter based on configured path
            # Skip if filter_by_record is provided - it already scopes to user's data
            query =
              if filter_by_record do
                query
              else
                user_id_path = Keyword.get(opts, :user_id_path, [:user_id])
                user_filter = build_user_filter(user_id_path, recipient.id)
                Ash.Query.filter(query, ^user_filter)
              end

            # Apply dynamic filter by record field (e.g., cart_id from Cart)
            query = apply_filter_by_record(query, record, filter_by_record)

            Ash.count!(query, authorize?: false)
          else
            # Global: count all items (admin/system counters)
            query = Ash.Query.new(resource)

            # Apply static filter only if not empty/nil
            query = apply_query_filter(query, query_filter)

            # Apply dynamic filter by record field
            query = apply_filter_by_record(query, record, filter_by_record)

            Ash.count!(query, authorize?: false)
          end
        rescue
          e ->
            Logger.error(
              "[BroadcastCounterUpdate] Failed to count #{counter_name}: #{inspect(e)}\n" <>
                "Resource: #{inspect(resource)}, Query filter: #{inspect(query_filter)}"
            )

            0
        end

      # Broadcast to recipient
      Logger.debug("[BroadcastCounterUpdate] Broadcasting #{counter_name}=#{count} to user #{recipient.id}")
      broadcast_to_user(recipient.id, counter_name, count, invalidates, audience)
    end)
  end

  # Resolve recipients for counter broadcasting using unified system
  defp resolve_recipients_for_counter(record, audience, opts) do
    case audience do
      :user ->
        # For :user audience, extract the user from the record
        case extract_user_from_record(record, opts) do
          nil -> []
          user -> [user]
        end

      _ ->
        # For :admin, :system, or custom audiences, use event system
        channel = %{audience: audience}
        AshDispatch.Event.Helpers.resolve_recipients_for_audience(nil, channel)
    end
  end

  # Extract user from record (supports nested relationships)
  defp extract_user_from_record(record, opts) do
    user_id = extract_user_id(record, opts)

    if user_id do
      # Return minimal user struct with id (same format as Event.Helpers)
      %{id: user_id}
    else
      nil
    end
  end

  # Extract user_id from record, supporting nested relationship paths
  defp extract_user_id(record, opts) do
    case Keyword.get(opts, :user_id_path) do
      nil ->
        # Fallback to direct field lookup
        user_id_field = Keyword.get(opts, :user_id_field, :user_id)
        Map.get(record, user_id_field)

      path when is_list(path) ->
        # Load and traverse relationship path to get user_id
        # Example: [:cart, :user_id] loads cart, then gets user_id from cart
        case load_and_traverse_path(record, path) do
          {:ok, user_id} -> user_id
          {:error, reason} ->
            Logger.warning(
              "[BroadcastCounterUpdate] Failed to resolve user_id via path #{inspect(path)}: #{inspect(reason)}"
            )
            nil
        end
    end
  end

  # Load relationships and traverse the path to extract the final value
  defp load_and_traverse_path(record, path) do
    # Split path into relationships to load and final field
    # Example: [:cart, :user_id] -> load [:cart], then get .cart.user_id
    {relationships, [_final_field]} = Enum.split(path, -1)

    # Load all relationships in the path
    case Ash.load(record, relationships, authorize?: false) do
      {:ok, loaded_record} ->
        # Traverse the path to get the final value
        value = get_nested_value(loaded_record, path)
        {:ok, value}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Recursively traverse a nested path to extract a value
  defp get_nested_value(record, [field]) do
    Map.get(record, field)
  end

  defp get_nested_value(record, [field | rest]) do
    case Map.get(record, field) do
      nil -> nil
      nested_record -> get_nested_value(nested_record, rest)
    end
  end

  # Apply query_filter keyword list using expr() macro
  defp apply_query_filter(query, query_filter) when is_list(query_filter) and query_filter != [] do
    # Convert keyword list to expr() filters
    # Example: [status: :pending] -> filter(query, status == :pending)
    Enum.reduce(query_filter, query, fn {field, value}, acc_query ->
      import Ash.Query
      import Ash.Expr

      filter(acc_query, ^ref(field) == ^value)
    end)
  end

  defp apply_query_filter(query, _query_filter), do: query

  # Apply filter by record field (e.g., filter CartItem by cart_id from Cart)
  defp apply_filter_by_record(query, _record, nil), do: query

  defp apply_filter_by_record(query, record, filter_config) do
    # Extract configuration
    filter_field = get_config_value(filter_config, :field)
    record_field = get_config_value(filter_config, :record_field, :id)

    if filter_field do
      # Get the value from the triggering record
      filter_value = Map.get(record, record_field)

      if filter_value do
        # Apply filter using expr macro for proper filter construction
        import Ash.Query
        import Ash.Expr

        filter(query, ^ref(filter_field) == ^filter_value)
      else
        Logger.warning(
          "[BroadcastCounterUpdate] Could not extract #{record_field} from record for filtering"
        )

        query
      end
    else
      query
    end
  end

  # Helper to get value from keyword list or map
  defp get_config_value(config, key, default \\ nil) do
    cond do
      is_list(config) -> Keyword.get(config, key, default)
      is_map(config) -> Map.get(config, key, default)
      true -> default
    end
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

  defp broadcast_to_user(user_id, counter_name, count, invalidates, _audience) do
    # Get configured broadcast function
    case Application.get_env(:ash_dispatch, :counter_broadcast_fn) do
      nil ->
        Logger.warning(
          "[BroadcastCounterUpdate] No counter_broadcast_fn configured, skipping broadcast"
        )

      broadcast_fn when is_function(broadcast_fn, 4) ->
        # Function capture: &Module.function/4
        metadata = %{invalidate_queries: invalidates}
        broadcast_fn.(user_id, counter_name, count, metadata: metadata)

      {module, function} when is_atom(module) and is_atom(function) ->
        # MFA tuple: {Module, :function}
        metadata = %{invalidate_queries: invalidates}
        apply(module, function, [user_id, counter_name, count, [metadata: metadata]])

      other ->
        Logger.error(
          "[BroadcastCounterUpdate] Invalid counter_broadcast_fn config: #{inspect(other)}"
        )
    end
  end
end
