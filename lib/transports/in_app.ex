defmodule AshDispatch.Transports.InApp do
  @moduledoc """
  In-app notification transport.

  Creates in-app notifications immediately (synchronous).

  ## Behavior

  1. Checks user preferences (if event is user_configurable)
  2. Resolves recipients from context
  3. Creates Notification records
  4. Updates receipt status to `:sent`

  ## Status Flow

  ```
  pending → sent (success)
          ↘ failed (error)
          ↘ skipped (user opted out)
  ```

  ## Example

      receipt = %{
        content: %{
          title: "Order Created",
          message: "Your order #1234 is being processed",
          action_url: "/orders/1234",
          notification_type: :success
        }
      }

      InApp.deliver(receipt, context, channel, event_config)
      # -> Creates Notification records
      # -> Returns {:ok, updated_receipt}
  """

  import AshDispatch.ContentMap

  alias AshDispatch.Config

  require Logger

  @doc """
  Delivers an in-app notification.

  ## Parameters

  - `receipt` - DeliveryReceipt map
  - `context` - Event context
  - `channel` - Channel configuration
  - `event_config` - Event configuration

  ## Returns

  - `{:ok, updated_receipt}` on success
  - `{:error, reason}` on failure
  """
  def deliver(receipt, context, channel, event_config) do
    # Check user preferences first
    if not AshDispatch.UserPreference.allows?(context, channel, event_config) do
      Logger.info("User opted out of #{context.event_id} via #{channel.transport}, skipping")

      updated_receipt =
        receipt
        |> Ash.Changeset.for_update(:skip, %{error_message: "user_opted_out"})
        |> Ash.update!()

      {:ok, updated_receipt}
    else
      # Receipt now corresponds to a single recipient (user_id in receipt)
      # Create one notification for this recipient
      invalidates = event_config[:invalidates] || []
      result = create_notification_for_receipt(receipt, context, channel, invalidates)

      # Update receipt status and link notification_id
      updated_receipt = update_receipt_with_notification(receipt, result)

      {:ok, updated_receipt}
    end
  rescue
    error ->
      Logger.error("""
      InApp transport failed
      Event: #{context.event_id}
      Error: #{inspect(error)}
      """)

      {:error, error}
  end

  @doc """
  Retry a failed in-app delivery directly from a stored receipt.

  In-app delivery is synchronous (DB write + PubSub broadcast), so we
  re-attempt the Notification.create directly rather than going through Oban.

  Uses the receipt's stored content and idempotency_key to prevent duplicates.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  def retry_from_receipt(receipt) do
    user_id = receipt.user_id
    content = receipt.content || %{}

    if is_nil(user_id) do
      {:error, :no_user_id}
    else
      # Rebuild idempotency key from receipt fields to match original delivery format.
      # Original format: "event_id:source_id:audience:user_id" or "event_id:audience:user_id"
      idempotency_key =
        case receipt do
          %{source_id: source_id} when is_binary(source_id) and source_id != "" ->
            "#{receipt.event_id}:#{source_id}:#{receipt.audience}:#{user_id}"

          _ ->
            "#{receipt.event_id}:#{receipt.audience}:#{user_id}"
        end

      notification_attrs = %{
        user_id: user_id,
        title: get_content(content, :title),
        message: get_content(content, :message),
        action_url: get_content(content, :action_url),
        action_label: get_content(content, :action_label),
        event_id: receipt.event_id,
        source: receipt.event_id,
        type: get_notification_type(content),
        metadata: get_content(content, :metadata) || %{},
        idempotency_key: idempotency_key
      }

      notification_resource = Config.notification_resource()

      case notification_resource
           |> Ash.Changeset.for_create(:create, notification_attrs)
           |> Ash.create() do
        {:ok, notification} ->
          # Broadcast and mark receipt as sent
          invalidates = Map.get(content, :invalidates, [])
          broadcast_notification(notification, invalidates)

          receipt
          |> Ash.Changeset.for_update(:mark_sent, %{notification_id: notification.id})
          |> Ash.update(authorize?: false)

          :ok

        {:error, reason} ->
          Logger.error(
            "InApp retry failed: receipt_id=#{receipt.id}, reason=#{inspect(reason)}"
          )

          {:error, reason}
      end
    end
  end

  # Private functions

  # Create notification for the receipt (one receipt = one recipient now)
  defp create_notification_for_receipt(receipt, context, channel, invalidates) do
    # Receipt now has the user_id of the recipient
    user_id = receipt.user_id

    # Skip in-app notifications if no user_id (external recipients, webhooks, etc.)
    cond do
      is_nil(user_id) ->
        Logger.warning("""
        Skipping in-app notification creation: no user_id
        Event: #{context.event_id}
        Recipient: #{receipt.recipient}

        In-app notifications require a valid user_id. This receipt will be skipped.
        """)

        # Skip the receipt since in-app notifications require user_id
        {:error, :no_user_id}

      true ->
        # Generate idempotency key to prevent duplicates when user receives
        # notifications from multiple audiences (e.g., user who is also admin)
        # Format: "event_id:resource_id:audience:user_id" or "event_id:audience:user_id" if no resource_id
        idempotency_key =
          case extract_resource_id(context) do
            nil -> "#{context.event_id}:#{channel.audience}:#{user_id}"
            resource_id -> "#{context.event_id}:#{resource_id}:#{channel.audience}:#{user_id}"
          end

        # Build metadata from event config + context priority
        metadata =
          (receipt.content[:metadata] || %{})
          |> Map.put(:priority, context.priority || :standard)

        notification_attrs = %{
          user_id: user_id,
          title: get_content(receipt.content, :title),
          message: get_content(receipt.content, :message),
          action_url: get_content(receipt.content, :action_url),
          action_label: get_content(receipt.content, :action_label),
          event_id: context.event_id,
          source: context.event_id,
          type: get_notification_type(receipt.content),
          metadata: metadata,
          idempotency_key: idempotency_key
        }

        # Create Notification record via Ash
        notification_resource = Config.notification_resource()

        case notification_resource
             |> Ash.Changeset.for_create(:create, notification_attrs)
             |> Ash.create() do
          {:ok, notification} ->
            Logger.debug("""
            Created in-app notification:
            User: #{notification.user_id}
            Title: #{notification.title}
            Message: #{notification.message}
            """)

            # Broadcast to user's channel with invalidation keys
            broadcast_notification(notification, invalidates)

            {:ok, notification}

          {:error, error} ->
            Logger.error("""
            Failed to create in-app notification:
            User: #{notification_attrs.user_id}
            Error: #{inspect(error)}
            """)

            {:error, error}
        end
    end
  end

  # Update receipt with notification_id and mark as sent
  defp update_receipt_with_notification(receipt, result) do
    case result do
      {:ok, notification} ->
        receipt
        |> Ash.Changeset.for_update(:mark_sent, %{notification_id: notification.id})
        |> Ash.update!()

      {:error, :no_user_id} ->
        # Skip receipts for external recipients without user_ids
        receipt
        |> Ash.Changeset.for_update(:skip, %{
          error_message: "In-app notifications require user_id (external recipient)"
        })
        |> Ash.update!()

      {:error, reason} ->
        receipt
        |> Ash.Changeset.for_update(:mark_failed, %{error_message: inspect(reason)})
        |> Ash.update!()
    end
  end

  # Extract the primary resource ID from context data
  # Used for idempotency keys to prevent duplicate notifications
  defp extract_resource_id(%{data: data}) when is_map(data) do
    # Find the first value in data map that has an :id field
    data
    |> Map.values()
    |> Enum.find_value(fn
      %{id: id} when is_binary(id) -> id
      _ -> nil
    end)
  end

  defp extract_resource_id(_), do: nil

  # Get notification type, converting string values to atoms and defaulting to :info
  defp get_notification_type(content) do
    case get_content(content, :notification_type) do
      type when is_atom(type) -> type
      "success" -> :success
      "info" -> :info
      "warning" -> :warning
      "error" -> :error
      _ -> :info
    end
  end

  # Broadcast notification to user's channel in JSON-serializable format
  defp broadcast_notification(notification, invalidates) do
    pubsub_module = Config.pubsub_module()

    if pubsub_module do
      serialized = %{
        id: notification.id,
        type: notification.type,
        title: notification.title,
        message: notification.message,
        read: notification.read,
        source: notification.source,
        occurredAt: notification.occurred_at,
        insertedAt: notification.inserted_at,
        metadata: notification.metadata || %{},
        actionLabel: notification.action_label,
        actionUrl: notification.action_url,
        invalidates: invalidates
      }

      topic = "#{Config.channel_topic()}:#{notification.user_id}"

      pubsub_module.broadcast(
        topic,
        "new_notification",
        serialized
      )
    end
  end
end
