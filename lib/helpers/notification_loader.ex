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

  alias AshDispatch.Config

  require Ash.Query
  require Logger

  @doc """
  Load recent notifications for a user.

  Returns serialized notifications ready for JSON/frontend consumption.

  ## Options

  - `:limit` - Number of notifications to load (default: 50)
  - `:serializer` - Custom serialization function (default: built-in serializer)
  - `:tenant` - the tenant to read in. Required when the notification resource
    is per tenant (`multitenancy: :context`), ignored otherwise. Since 0.9.4

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
    resource = Config.notification_resource()

    resource
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read([authorize?: false] ++ tenant_opts(opts))
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
      actionUrl: notification.action_url,
      category: Map.get(notification, :category),
      seenAt: Map.get(notification, :seen_at),
      archivedAt: Map.get(notification, :archived_at)
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
    tenant = Keyword.get(opts, :tenant)
    read_opts = [actor: actor] ++ tenant_opts(opts)

    with {:ok, notification} <-
           Config.notification_resource()
           |> Ash.get(notification_id, read_opts),
         {:ok, updated} <-
           notification
           |> Ash.Changeset.for_update(:mark_as_read, %{}, actor: actor)
           |> AshDispatch.Tenancy.set(tenant)
           |> Ash.update() do
      {:ok, updated}
    end
  end

  # `:tenant` means two things, and which one is the resource's business: for a
  # notification resource built with `multitenancy: :context` it is the schema;
  # for one in the public schema it is the `tenant` column, which the actions
  # filter on through an argument. A host passes it once either way.
  defp tenant_opts(opts) do
    AshDispatch.Tenancy.opts(Config.notification_resource(), Keyword.get(opts, :tenant))
  end

  @doc """
  Mark all notifications as read for a user.

  Uses the mark_all_as_read action which properly triggers counter broadcasts.

  ## Options

  - `:actor` - User performing the action (for authorization)
  - `:authorize?` - Passed on to the action
  - `:tenant` - only this tenant's notifications (and those without a
    tenant). Since 0.9.0

  ## Examples

      NotificationLoader.mark_all_as_read(user_id, actor: current_user)
      #=> {:ok, %{success: true}}

  ## Returns

  - `{:ok, %{success: true}}` - Successfully marked notifications as read
  - `{:error, reason}` - Failed (e.g. forbidden: `user_id` is not the actor's)

  Until 0.8.8 the options were ignored and the action ran without an actor,
  so the resource's policy (`user_id` must be the actor's) refused every call.
  `:actor` and `:authorize?` are passed on now.
  """
  def mark_all_as_read(user_id, opts \\ []) do
    case Keyword.get(opts, :tenant) do
      nil ->
        Config.notification_resource().mark_all_as_read(user_id, action_opts(opts))

      tenant ->
        Config.notification_resource()
        |> Ash.ActionInput.for_action(
          :mark_all_as_read,
          %{user_id: user_id, tenant: AshDispatch.Context.tenant_key(tenant)},
          action_opts(opts) ++ tenant_opts(opts)
        )
        |> Ash.run_action()
    end
  end

  @doc """
  How many unread, not archived notifications the actor has.

  ## Options

  - `:actor` - (required) the user
  - `:tenant` - only count notifications of this tenant

  ## Examples

      NotificationLoader.unread_count(actor: current_user)
      #=> {:ok, 3}
  """
  @spec unread_count(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def unread_count(opts) do
    input =
      case Keyword.get(opts, :tenant) do
        nil -> %{}
        tenant -> %{tenant: AshDispatch.Context.tenant_key(tenant)}
      end

    Config.notification_resource()
    |> Ash.ActionInput.for_action(:unread_count, input, action_opts(opts) ++ tenant_opts(opts))
    |> Ash.run_action()
  end

  @doc """
  Tells a user's open screens that notifications were read, so a bell in
  another tab can count again. Broadcasts `"notifications_read"` on the
  user's topic (`AshDispatch.Config.channel_topic/0`) through the configured
  `:pubsub_module`; does nothing without one.

  The notification resource calls it after `mark_as_read` and
  `mark_all_as_read`.
  """
  @spec broadcast_read(term()) :: :ok
  def broadcast_read(nil), do: :ok

  def broadcast_read(user_id) do
    case Config.pubsub_module() do
      nil ->
        :ok

      pubsub ->
        pubsub.broadcast("#{Config.channel_topic()}:#{user_id}", "notifications_read", %{
          userId: user_id
        })

        :ok
    end
  rescue
    error ->
      Logger.warning("[NotificationLoader] broadcast_read failed: #{Exception.message(error)}")
      :ok
  end

  defp action_opts(opts), do: Keyword.take(opts, [:actor, :authorize?])
end
