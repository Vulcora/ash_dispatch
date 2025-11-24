defmodule AshDispatch.Helpers.NotificationLoader do
  @moduledoc """
  Helper for loading and managing notifications.

  Automatically discovers the notification resource from AshDispatch.Resources.Notification
  and provides common operations.

  ## Usage

      alias AshDispatch.Helpers.NotificationLoader

      # Load recent notifications
      notifications = NotificationLoader.load_recent(user_id)
      #=> [%{id: "...", title: "...", ...}]

      # Mark as read
      NotificationLoader.mark_as_read(notification_id, actor: user)

      # Mark all as read
      NotificationLoader.mark_all_as_read(user_id, actor: user)

  ## Custom Serialization

  Apps can provide custom serializers:

      NotificationLoader.load_recent(user_id,
        serializer: &MyApp.serialize_notification/1
      )
  """

  require Ash.Query
  require Logger

  @doc """
  Load recent notifications for a user.

  Returns serialized notifications ready for JSON/frontend consumption.

  ## Options

  - `:limit` - Number of notifications to load (default: 50)
  - `:serializer` - Custom serialization function (default: built-in serializer)

  ## Examples

      # Default serialization
      NotificationLoader.load_recent("user-123")
      #=> [%{id: "...", title: "...", read: false, ...}]

      # Custom limit
      NotificationLoader.load_recent("user-123", limit: 10)

      # Custom serializer
      NotificationLoader.load_recent("user-123",
        serializer: &MyApp.serialize_notification/1
      )
  """
  def load_recent(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    serializer = Keyword.get(opts, :serializer)

    notification_resource()
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, notifications} ->
        Enum.map(notifications, fn notification ->
          if serializer do
            serializer.(notification)
          else
            serialize(notification)
          end
        end)

      {:error, error} ->
        Logger.error("[NotificationLoader] Failed to load notifications: #{inspect(error)}")
        []

      _ ->
        []
    end
  end

  @doc """
  Serialize a notification for JSON/frontend consumption.

  Uses camelCase keys for JavaScript compatibility.
  Apps can provide custom serializers via options.

  ## Examples

      NotificationLoader.serialize(notification)
      #=> %{id: "...", title: "...", actionLabel: "View", ...}
  """
  def serialize(notification) do
    %{
      id: notification.id,
      type: notification.type,
      title: notification.title,
      message: notification.message,
      read: notification.read,
      timestamp: notification.inserted_at,
      metadata: notification.metadata,
      actionLabel: notification.action_label,
      actionUrl: notification.action_url
    }
  end

  @doc """
  Mark a notification as read.

  Uses Ash policies to verify ownership.

  ## Options

  - `:actor` - User performing the action (for authorization)

  ## Examples

      NotificationLoader.mark_as_read(notification_id, actor: current_user)
      #=> {:ok, updated_notification}

  ## Returns

  - `{:ok, notification}` - Successfully marked as read
  - `{:error, reason}` - Failed (unauthorized, not found, etc.)
  """
  def mark_as_read(notification_id, opts \\ []) do
    actor = Keyword.get(opts, :actor)

    with {:ok, notification} <-
           notification_resource()
           |> Ash.get(notification_id, actor: actor),
         {:ok, updated} <-
           notification
           |> Ash.Changeset.for_update(:mark_as_read, %{}, actor: actor)
           |> Ash.update() do
      {:ok, updated}
    end
  end

  @doc """
  Mark all notifications as read for a user.

  Uses the mark_all_as_read action which properly triggers counter broadcasts.

  ## Options

  - `:actor` - User performing the action (for authorization)

  ## Examples

      NotificationLoader.mark_all_as_read(user_id, actor: current_user)
      #=> {:ok, %{marked_count: 5}}

  ## Returns

  - `{:ok, %{marked_count: integer}}` - Successfully marked notifications as read
  - `{:error, reason}` - Failed to mark notifications
  """
  def mark_all_as_read(user_id, _opts \\ []) do
    notification_resource().mark_all_as_read(user_id)
  end

  # Get configured notification resource or fall back to default
  defp notification_resource do
    Application.get_env(:ash_dispatch, :notification_resource, AshDispatch.Resources.Notification)
  end
end
