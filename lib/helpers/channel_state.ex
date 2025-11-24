defmodule AshDispatch.Helpers.ChannelState do
  @moduledoc """
  Helper for building initial Phoenix Channel state.

  Combines counters and notifications into a single payload ready for
  Phoenix Channel's `push/2`. Loads data in parallel for performance.

  ## Usage

      alias AshDispatch.Helpers.ChannelState

      # Build complete initial state
      initial_state = ChannelState.build(user_id)
      #=> %{"counters" => %{...}, "notifications" => [...]}

      push(socket, "initial_state", initial_state)

  ## Custom Options

      # Limit notifications
      ChannelState.build(user_id, notification_limit: 10)

      # Load counters from specific domains
      ChannelState.build(user_id, counter_domains: [MyApp.Orders])

      # Custom notification serializer
      ChannelState.build(user_id,
        notification_serializer: &MyApp.serialize_notification/1
      )
  """

  alias AshDispatch.Helpers.{CounterLoader, NotificationLoader}

  @doc """
  Build complete initial state for a user.

  Loads counters and notifications in parallel for optimal performance.

  Returns a map with:
  - `"counters"` - All counters as camelCase JSON (strings for JS)
  - `"notifications"` - Recent notifications

  ## Options

  - `:notification_limit` - Number of recent notifications (default: 50)
  - `:notification_serializer` - Custom notification serializer function
  - `:counter_domains` - Specific Ash domains to load counters from
  - `:parallel` - Load in parallel (default: true)

  ## Examples

      # Standard usage
      ChannelState.build("user-123")
      #=> %{
      #     "counters" => %{"pending_orders" => 5, "cart_items" => 3},
      #     "notifications" => [%{id: "...", ...}, ...]
      #   }

      # With options
      ChannelState.build("user-123",
        notification_limit: 10,
        counter_domains: [MyApp.Orders, MyApp.Tickets]
      )

      # Custom serializer
      ChannelState.build("user-123",
        notification_serializer: &MyApp.serialize_notification/1
      )
  """
  def build(user_id, opts \\ []) do
    notification_limit = Keyword.get(opts, :notification_limit, 50)
    notification_serializer = Keyword.get(opts, :notification_serializer)
    parallel = Keyword.get(opts, :parallel, true)

    if parallel do
      build_parallel(user_id, opts, notification_limit, notification_serializer)
    else
      build_sequential(user_id, opts, notification_limit, notification_serializer)
    end
  end

  # Load counters and notifications in parallel
  defp build_parallel(user_id, opts, notification_limit, notification_serializer) do
    counters_task =
      Task.async(fn ->
        CounterLoader.load_counters_for_user(user_id, opts)
      end)

    notifications_task =
      Task.async(fn ->
        NotificationLoader.load_recent(user_id,
          limit: notification_limit,
          serializer: notification_serializer
        )
      end)

    counters = Task.await(counters_task)
    notifications = Task.await(notifications_task)

    %{
      "counters" => counters_to_json(counters),
      "notifications" => notifications
    }
  end

  # Load counters and notifications sequentially (useful for testing or debugging)
  defp build_sequential(user_id, opts, notification_limit, notification_serializer) do
    counters = CounterLoader.load_counters_for_user(user_id, opts)

    notifications =
      NotificationLoader.load_recent(user_id,
        limit: notification_limit,
        serializer: notification_serializer
      )

    %{
      "counters" => counters_to_json(counters),
      "notifications" => notifications
    }
  end

  @doc """
  Convert counter map to JSON-friendly format.

  Converts atom keys to strings for JavaScript consumption.

  ## Examples

      ChannelState.counters_to_json(%{pending_orders: 5, cart_items: 3})
      #=> %{"pending_orders" => 5, "cart_items" => 3}
  """
  def counters_to_json(counters) when is_map(counters) do
    Enum.into(counters, %{}, fn {key, value} ->
      {Atom.to_string(key), value}
    end)
  end

  def counters_to_json(_), do: %{}

  @doc """
  Build only counters (no notifications).

  Useful when you only need to refresh counters without notifications.

  ## Examples

      ChannelState.build_counters(user_id)
      #=> %{"counters" => %{"pending_orders" => 5}}
  """
  def build_counters(user_id, opts \\ []) do
    counters = CounterLoader.load_counters_for_user(user_id, opts)

    %{
      "counters" => counters_to_json(counters)
    }
  end

  @doc """
  Build only notifications (no counters).

  Useful when you only need to refresh notifications without counters.

  ## Options

  - `:limit` - Number of notifications (default: 50)
  - `:serializer` - Custom serializer function

  ## Examples

      ChannelState.build_notifications(user_id)
      #=> %{"notifications" => [%{id: "...", ...}]}

      ChannelState.build_notifications(user_id, limit: 10)
  """
  def build_notifications(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    serializer = Keyword.get(opts, :serializer)

    notifications =
      NotificationLoader.load_recent(user_id,
        limit: limit,
        serializer: serializer
      )

    %{
      "notifications" => notifications
    }
  end
end
