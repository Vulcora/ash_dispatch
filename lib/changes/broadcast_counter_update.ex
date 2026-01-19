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

  The counter system requires a configured broadcast function:

      config :ash_dispatch,
        counter_broadcast_fn: &MyAppWeb.CounterBroadcaster.broadcast/4

  See `AshDispatch.Behaviours.CounterBroadcaster` for implementation details.

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

  alias AshDispatch.Config
  alias AshDispatch.Helpers.ResourceIntrospection

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

    # Resolve recipients using unified system (same as events)
    recipients = resolve_recipients_for_counter(record, audience, opts)

    # Get authorization and scoping options
    authorize? = Keyword.get(opts, :authorize?, true)
    scope = Keyword.get(opts, :scope)

    # Use consolidated helper for user_id_path resolution
    user_id_path =
      ResourceIntrospection.resolve_user_id_path_for_scoping(resource,
        authorize?: authorize?,
        scope: scope,
        user_id_path: Keyword.get(opts, :user_id_path),
        audience: audience
      )

    # For each recipient, execute query and broadcast
    Enum.each(recipients, fn recipient ->
      # Execute count query
      count =
        try do
          query =
            resource
            |> Ash.Query.new()

          # Apply static filter only if not empty/nil
          query = apply_query_filter(query, query_filter)

          # Apply scoping based on priority: scope > user_id_path > none
          # Skip if filter_by_record is provided - it already scopes to user's data
          query =
            cond do
              # Explicit scope expression takes precedence
              scope && !filter_by_record ->
                apply_scope_expression(query, scope, recipient)

              # Legacy user_id_path support
              user_id_path && !filter_by_record ->
                # Build user filter as keyword list and apply directly (no caret needed)
                user_filter = ResourceIntrospection.build_user_filter(user_id_path, recipient.id)
                Ash.Query.do_filter(query, user_filter)

              # No scoping (global counter or filter_by_record handles it)
              true ->
                query
            end

          # Apply dynamic filter by record field (e.g., cart_id from Cart)
          query = apply_filter_by_record(query, record, filter_by_record)

          # Use authorize? setting - false bypasses policies
          Ash.count!(query, authorize?: authorize?, actor: recipient)
        rescue
          e ->
            Logger.error(
              "[BroadcastCounterUpdate] Failed to count #{counter_name}: #{inspect(e)}\n" <>
                "Resource: #{inspect(resource)}, Query filter: #{inspect(query_filter)}"
            )

            0
        end

      broadcast_to_user(recipient.id, counter_name, count, invalidates, audience)
    end)
  end

  # Resolve recipients for counter broadcasting using audience config pattern.
  #
  # The audience configuration determines recipient resolution:
  # - Relationship-based (bare atom like :user) → extract from record
  # - Filter-based (tuple like {:admin, [...]}) → query all matching users
  # - MFA-based → call function with record to get dynamic recipients
  #
  # This aligns with the Ash philosophy of deriving behavior from configuration.
  defp resolve_recipients_for_counter(record, audience, opts) do
    if ResourceIntrospection.is_relationship_audience?(audience) do
      # Relationship-based: extract the single recipient from the record
      # e.g., :user → notification.user, :partner → order.partner
      case extract_user_from_record(record, audience, opts) do
        nil -> []
        user -> [user]
      end
    else
      # Filter-based or MFA-based: query all users matching the audience filter
      # e.g., :admin → all users where admin: true
      # e.g., :company_members → {Module, :resolve, [:resource]} → dynamic resolution
      # Build a context with the record so MFA functions can access it
      context = %{data: %{record: record}}
      channel = %{audience: audience}
      AshDispatch.Event.Helpers.resolve_recipients_for_audience(context, channel)
    end
  end

  # Extract user from record (supports nested relationships)
  # Uses audience to derive relationship name when user_id_path not explicit
  defp extract_user_from_record(record, audience, opts) do
    user_id = extract_user_id(record, audience, opts)

    if user_id do
      # Return minimal user struct with id (same format as Event.Helpers)
      %{id: user_id}
    else
      nil
    end
  end

  # Extract user_id from record, supporting nested relationship paths.
  # Uses audience to derive field name when not explicitly configured.
  defp extract_user_id(record, audience, opts) do
    case Keyword.get(opts, :user_id_path) do
      nil ->
        # Derive field from audience relationship name
        # e.g., :user → :user_id, :partner → :partner_id
        relationship_name = ResourceIntrospection.get_audience_relationship(audience)

        user_id_field =
          Keyword.get(opts, :user_id_field) ||
            (relationship_name && String.to_atom("#{relationship_name}_id")) ||
            :user_id

        Map.get(record, user_id_field)

      path when is_list(path) ->
        # Load and traverse relationship path to get user_id
        # Example: [:cart, :user_id] loads cart, then gets user_id from cart
        case load_and_traverse_path(record, path) do
          {:ok, user_id} ->
            user_id

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

  # Apply query_filter - supports both Ash expressions and keyword lists
  #
  # Ash.Expr format (from counter DSL with expr()):
  #   query_filter: expr(status == :pending and is_nil(deleted_at))
  #
  # Keyword list format (legacy):
  #   query_filter: [status: :pending]
  defp apply_query_filter(query, nil), do: query
  defp apply_query_filter(query, []), do: query

  defp apply_query_filter(query, query_filter) when is_list(query_filter) do
    # Check if it's a keyword list (legacy format) or something else
    if Keyword.keyword?(query_filter) do
      # Keyword list format - convert to filters
      # Example: [status: :pending] -> filter(query, status == :pending)
      Enum.reduce(query_filter, query, fn {field, value}, acc_query ->
        import Ash.Query
        import Ash.Expr

        if is_list(value) do
          filter(acc_query, ^ref(field) in ^value)
        else
          filter(acc_query, ^ref(field) == ^value)
        end
      end)
    else
      # Non-keyword list - might be some other filter format, skip
      Logger.warning(
        "[BroadcastCounterUpdate] Unknown query_filter format (non-keyword list): #{inspect(query_filter)}"
      )

      query
    end
  end

  defp apply_query_filter(query, query_filter) do
    Ash.Query.filter(query, ^query_filter)
  rescue
    # If query_filter doesn't have __struct__ or filter fails
    e ->
      Logger.warning(
        "[BroadcastCounterUpdate] Failed to apply query_filter: #{inspect(e)}, filter: #{inspect(query_filter)}"
      )

      query
  end

  # Apply scope expression with recipient as actor context.
  #
  # Scope expressions can use ^actor(:field) templates to reference
  # the recipient's attributes. For example:
  #   scope: expr(user_id == ^actor(:id))
  #   scope: expr(region == ^actor(:region))
  #   scope: expr(assigned_support.team_id == ^actor(:team_id))
  #
  # The expression is applied as a filter to the query.
  defp apply_scope_expression(query, scope_expr, recipient) do
    # Set the actor context so ^actor(:field) templates resolve correctly
    query
    |> Ash.Query.set_context(%{actor: recipient})
    |> Ash.Query.filter(^scope_expr)
  end

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

  defp broadcast_to_user(user_id, counter_name, count, invalidates, _audience) do
    # Get configured broadcast function
    case Config.counter_broadcast_fn() do
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
