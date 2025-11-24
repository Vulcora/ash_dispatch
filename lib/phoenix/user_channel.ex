defmodule AshDispatch.Phoenix.UserChannel do
  @moduledoc """
  Macro for creating a user channel with all AshDispatch functionality built-in.

  Provides real-time updates for:
  - Notifications
  - Counter updates
  - Query invalidation

  ## Usage

  Create your channel with just 3 lines:

      defmodule MyAppWeb.UserChannel do
        use AshDispatch.Phoenix.UserChannel,
          endpoint: MyAppWeb.Endpoint
      end

  Add to your socket:

      channel "user:*", MyAppWeb.UserChannel

  ## What You Get

  - `join/3` - Authorizes and initializes channel
  - `handle_info(:after_join, socket)` - Sends initial counters/notifications
  - `handle_in("refresh_counters", ...)` - Client can request counter refresh
  - `broadcast_notification/2` - Push notifications to user
  - `broadcast_counter/4` - Push counter updates with metadata
  - `broadcast_counters/2` - Push multiple counter updates

  ## Configuration

  The endpoint option is required. It's used for broadcasting.

      use AshDispatch.Phoenix.UserChannel,
        endpoint: MyAppWeb.Endpoint

  ## Customization

  You can override any callback by defining it in your module:

      defmodule MyAppWeb.UserChannel do
        use AshDispatch.Phoenix.UserChannel,
          endpoint: MyAppWeb.Endpoint

        # Custom join logic
        def join("user:" <> user_id, payload, socket) do
          # Your custom authorization
          if authorized?(socket, user_id) do
            send(self(), :after_join)
            {:ok, socket}
          else
            {:error, %{reason: "unauthorized"}}
          end
        end
      end

  ## Frontend Integration

  Use the generated SDK hooks to connect:

      import { useChannel } from '@/lib/ash-dispatch'

      function App() {
        useChannel({
          channel: userChannel,
          onNotification: (notification) => {
            // Handle new notification
          }
        })
      }
  """

  defmacro __using__(opts) do
    endpoint = Keyword.fetch!(opts, :endpoint)

    quote do
      use Phoenix.Channel

      alias AshDispatch.Helpers.{ChannelState, CounterLoader}

      @endpoint unquote(endpoint)

      @impl true
      def join("user:" <> user_id, _payload, socket) do
        # Verify the user is authorized (token verification already done in UserSocket)
        if socket.assigns.user_id == user_id do
          send(self(), :after_join)
          {:ok, socket}
        else
          {:error, %{reason: "unauthorized"}}
        end
      end

      @impl true
      def handle_info(:after_join, socket) do
        user_id = socket.assigns.user_id

        # Build complete initial state (counters + notifications in parallel)
        initial_state = ChannelState.build(user_id)

        push(socket, "initial_state", initial_state)
        {:noreply, socket}
      end

      # Client requests to refresh counters
      @impl true
      def handle_in("refresh_counters", _payload, socket) do
        user_id = socket.assigns.user_id
        counters = CounterLoader.load_counters_for_user(user_id)
        {:reply, {:ok, %{counters: counters}}, socket}
      end

      ## Broadcaster functions called from other parts of the app

      @doc """
      Broadcast a new notification to a user.
      Called automatically by the notification dispatcher.
      """
      def broadcast_notification(user_id, notification) do
        @endpoint.broadcast("user:#{user_id}", "new_notification", notification)
      end

      @doc """
      Broadcast counter updates to a user.
      Call this whenever a counter changes (e.g., new ticket, cart updated, etc.)
      """
      def broadcast_counters(user_id, counters) do
        @endpoint.broadcast("user:#{user_id}", "counters_updated", %{counters: counters})
      end

      @doc """
      Broadcast a counter update to a specific user.

      Unified method for all counter types - user, admin, system, custom.
      Counter routing is determined by the counter name itself.

      Options:
      - `:metadata` - Map with optional `invalidate_queries` list
      """
      def broadcast_counter(user_id, counter_name, value, opts \\ []) do
        metadata = Keyword.get(opts, :metadata, %{})

        @endpoint.broadcast("user:#{user_id}", "counter_updated", %{
          counter: counter_name,
          value: value,
          metadata: metadata
        })
      end

      # Allow overriding any function
      defoverridable [
        join: 3,
        handle_info: 2,
        handle_in: 3,
        broadcast_notification: 2,
        broadcast_counters: 2,
        broadcast_counter: 4
      ]
    end
  end
end
