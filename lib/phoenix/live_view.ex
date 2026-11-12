if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule AshDispatch.Phoenix.LiveView do
    @moduledoc """
    In-app notifications in a LiveView, without a JavaScript client.

    An `on_mount` hook that subscribes the LiveView to the signed-in user's
    topic and keeps their unread count in an assign, live:

        # router.ex
        live_session :app,
          on_mount: [
            MyAppWeb.UserAuth,
            {AshDispatch.Phoenix.LiveView, :notifications}
          ] do
          live "/", HomeLive
        end

        # any template in the session
        <span :if={@unread_notifications > 0}>{@unread_notifications}</span>

    The hook goes after the one that assigns the user. When a notification
    is created for the user (`:in_app` transport) or read in another tab
    (`mark_as_read`, `mark_all_as_read`), the count is read again and the
    assign updated. The messages are handled by a `handle_info` hook, so a
    LiveView needs no `handle_info/2` clause of its own for them.

    ## Reacting in a LiveView

    A LiveView that wants to do more — show a toast, prepend to a stream —
    defines `handle_notification/3`. It is called after the assign was
    updated, with the event (`"new_notification"` or `"notifications_read"`)
    and the broadcast payload:

        def handle_notification("new_notification", notification, socket) do
          {:noreply, stream_insert(socket, :notifications, notification, at: 0)}
        end

        def handle_notification(_event, _payload, socket), do: {:noreply, socket}

    ## Options

    Pass them as `{AshDispatch.Phoenix.LiveView, {:notifications, opts}}`:

    - `:user` - where the user is in the assigns: an atom or a path, e.g.
      `[:current_scope, :user]`. Default `:current_user`
    - `:tenant` - where the tenant is in the assigns (atom or path), to count
      only that tenant's notifications. Default: not filtered.

      Since 0.9.4 this means one of two things, and which one is the
      notification resource's business: for a resource built with
      `multitenancy: :context` it is the SCHEMA the count is read from, and for
      one in the public schema it is the `tenant` COLUMN the count filters on
      (where a notification without a tenant belongs to the person and is
      counted in every tenant). A LiveView passes it the same way either way
    - `:assign` - the assign holding the count. Default `:unread_notifications`

    ## Requirements

    - `config :ash_dispatch, pubsub_module: MyAppWeb.Endpoint` — the
      subscription goes through it (`subscribe/1`); without it the count is
      read at mount and not kept live
    - a notification resource (`AshDispatch.Resources.Notification.Base`,
      `config :ash_dispatch, notification_resource: ...`)

    The topic is `"\#{channel_topic}:\#{user_id}"` (`AshDispatch.Config.channel_topic/0`),
    the one the in-app transport broadcasts on.

    ## Helpers

    - `mark_all_as_read/1` — for a "mark all as read" button; sets the
      count to zero
    - `refresh/1` — reads the count again
    """

    import Phoenix.Component, only: [assign: 3]

    alias AshDispatch.Config
    alias AshDispatch.Helpers.NotificationLoader

    require Logger

    @hook_id :ash_dispatch_notifications
    @private_key :ash_dispatch_notifications
    @events ["new_notification", "notifications_read"]

    @doc false
    def on_mount(:notifications, params, session, socket),
      do: on_mount({:notifications, []}, params, session, socket)

    def on_mount({:notifications, opts}, _params, _session, socket) do
      opts = normalize(opts)
      user = fetch(socket.assigns, opts.user)

      case user do
        %{id: user_id} when not is_nil(user_id) ->
          topic = "#{Config.channel_topic()}:#{user_id}"
          state = Map.merge(opts, %{topic: topic})

          if Phoenix.LiveView.connected?(socket), do: subscribe(topic)

          socket =
            socket
            |> Phoenix.LiveView.put_private(@private_key, state)
            |> assign(opts.assign, count(socket.assigns, state))
            |> Phoenix.LiveView.attach_hook(@hook_id, :handle_info, &handle_info/2)

          {:cont, socket}

        _ ->
          {:cont, assign(socket, opts.assign, 0)}
      end
    end

    @doc """
    The `handle_info` hook: updates the count for this user's notification
    broadcasts and hands them to the LiveView's `handle_notification/3`,
    if it has one. Everything else passes through to the LiveView.
    """
    def handle_info(
          %{__struct__: Phoenix.Socket.Broadcast, topic: topic, event: event, payload: payload},
          socket
        )
        when event in @events do
      case socket.private[@private_key] do
        %{topic: ^topic} = state ->
          socket = assign(socket, state.assign, count(socket.assigns, state))
          {:halt, notify_view(socket, event, payload)}

        _ ->
          {:cont, socket}
      end
    end

    def handle_info(_message, socket), do: {:cont, socket}

    @doc "Reads the unread count again and assigns it."
    @spec refresh(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
    def refresh(socket) do
      case socket.private[@private_key] do
        nil -> socket
        state -> assign(socket, state.assign, count(socket.assigns, state))
      end
    end

    @doc """
    Marks all of the user's notifications as read (as the user, so the
    resource's policies apply) and sets the count to zero.

    Returns `{:ok, socket}` or `{:error, reason, socket}`.
    """
    @spec mark_all_as_read(Phoenix.LiveView.Socket.t()) ::
            {:ok, Phoenix.LiveView.Socket.t()} | {:error, term(), Phoenix.LiveView.Socket.t()}
    def mark_all_as_read(socket) do
      with %{} = state <- socket.private[@private_key],
           %{id: user_id} = user <- fetch(socket.assigns, state.user),
           {:ok, _} <-
             NotificationLoader.mark_all_as_read(user_id,
               actor: user,
               tenant: fetch(socket.assigns, state.tenant)
             ) do
        {:ok, assign(socket, state.assign, 0)}
      else
        {:error, reason} -> {:error, reason, socket}
        _ -> {:error, :no_user, socket}
      end
    end

    # ── private ───────────────────────────────────────────────────────

    defp normalize(opts) do
      opts = Map.new(opts)

      %{
        user: opts |> Map.get(:user, :current_user) |> List.wrap() |> nil_if_empty(),
        tenant: opts |> Map.get(:tenant) |> then(&if(&1, do: List.wrap(&1))),
        assign: Map.get(opts, :assign, :unread_notifications)
      }
    end

    defp nil_if_empty([]), do: nil
    defp nil_if_empty(path), do: path

    defp fetch(_assigns, nil), do: nil

    defp fetch(assigns, path) do
      Enum.reduce_while(path, assigns, fn key, acc ->
        case acc do
          %{} -> {:cont, Map.get(acc, key)}
          _ -> {:halt, nil}
        end
      end)
    end

    defp count(assigns, state) do
      user = fetch(assigns, state.user)

      case NotificationLoader.unread_count(actor: user, tenant: fetch(assigns, state.tenant)) do
        {:ok, count} ->
          count

        {:error, error} ->
          Logger.warning(
            "[AshDispatch.Phoenix.LiveView] unread count failed: #{Exception.message(Ash.Error.to_error_class(error))}"
          )

          0
      end
    rescue
      error ->
        Logger.warning(
          "[AshDispatch.Phoenix.LiveView] unread count failed: #{Exception.message(error)}"
        )

        0
    end

    defp subscribe(topic) do
      case Config.pubsub_module() do
        nil ->
          Logger.warning(
            "[AshDispatch.Phoenix.LiveView] no :pubsub_module configured; the unread count is not kept live"
          )

        pubsub ->
          if Code.ensure_loaded?(pubsub) and function_exported?(pubsub, :subscribe, 1) do
            pubsub.subscribe(topic)
          else
            Logger.warning(
              "[AshDispatch.Phoenix.LiveView] #{inspect(pubsub)} has no subscribe/1; the unread count is not kept live"
            )
          end
      end
    end

    defp notify_view(socket, event, payload) do
      view = socket.view

      if view && Code.ensure_loaded?(view) && function_exported?(view, :handle_notification, 3) do
        case view.handle_notification(event, payload, socket) do
          {:noreply, %Phoenix.LiveView.Socket{} = socket} -> socket
          {:noreply, %Phoenix.LiveView.Socket{} = socket, _opts} -> socket
          {:halt, %Phoenix.LiveView.Socket{} = socket} -> socket
          {:cont, %Phoenix.LiveView.Socket{} = socket} -> socket
          %Phoenix.LiveView.Socket{} = socket -> socket
        end
      else
        socket
      end
    end
  end
end
