defmodule AshDispatch.Transports.InApp do
  use AshDispatch.Transport, atom: :in_app, skip_receipt?: false

  @moduledoc """
  In-app notification transport.

  Creates in-app notifications immediately (synchronous).

  ## Behavior

  1. Checks the preferences of the receipt's own recipient
     (`AshDispatch.UserPreference.allows_receipt?/4`)
  2. Creates the Notification record for this receipt
  3. Updates receipt status to `:sent`

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
    # Check the preferences of THIS receipt's recipient. A receipt is one
    # recipient, so a fan-out evaluates one verdict per recipient — reading
    # `context.user` here applied the event subject's verdict to all N.
    if not AshDispatch.UserPreference.allows_receipt?(receipt, context, channel, event_config) do
      Logger.info(
        "User #{inspect(Map.get(receipt, :user_id))} opted out of #{context.event_id} via #{channel.transport}, skipping"
      )

      updated_receipt =
        receipt
        |> Ash.Changeset.for_update(:skip, %{error_message: "user_opted_out"})
        |> Ash.update!(authorize?: false)

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
  def retry_from_receipt(%{notification_id: notification_id} = receipt)
      when not is_nil(notification_id) do
    # The notification was created; only the receipt failed to record it. The
    # key rebuilt below cannot see a channel's `idempotency_source`, so
    # re-creating here would insert a second notification under a different
    # key. Settle the receipt instead.
    receipt
    |> Ash.Changeset.for_update(:mark_sent, %{})
    |> Ash.update(authorize?: false)

    :ok
  end

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

      # `authorize?: false`: the transport is system-internal. It runs in the
      # dispatch chain without an end user as actor, and the notification is
      # created FOR the recipient — not BY them. `Notification.Base` forbids
      # create/update/destroy from the outside, so without this no
      # notifications could be created at all.
      case notification_resource
           |> Ash.Changeset.for_create(:create, notification_attrs)
           |> Ash.create(authorize?: false) do
        {:ok, notification} ->
          # Broadcast and mark receipt as sent
          invalidates = Map.get(content, :invalidates, [])
          broadcast_notification(notification, invalidates)

          receipt
          |> Ash.Changeset.for_update(:mark_sent, %{notification_id: notification.id})
          |> Ash.update(authorize?: false)

          :ok

        {:error, error} ->
          # Duplicate idempotency key means the notification was already delivered —
          # treat as success and mark the receipt as sent.
          if idempotency_conflict?(error) do
            Logger.debug(
              "InApp retry: notification already exists (idempotency key match), marking receipt as sent: receipt_id=#{receipt.id}"
            )

            receipt
            |> Ash.Changeset.for_update(:mark_sent, %{})
            |> Ash.update(authorize?: false)

            :ok
          else
            Logger.error("InApp retry failed: receipt_id=#{receipt.id}, reason=#{inspect(error)}")

            {:error, error}
          end
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
        idempotency_key = idempotency_key(channel, context, user_id)

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

        # Create Notification record via Ash. `authorize?: false`: the
        # transport is system-internal and creates the notification FOR the
        # recipient without an actor — `Notification.Base` forbids external
        # create/update/destroy, so this must bypass policies.
        notification_resource = Config.notification_resource()

        case create_notification(notification_resource, notification_attrs, idempotency_key) do
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

          {:already_exists, existing} ->
            Logger.debug(
              "InApp: notification already exists (idempotency key match), treating as success: event=#{context.event_id}, user=#{user_id}"
            )

            {:ok, existing}

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
      {:ok, %{id: notification_id}} ->
        receipt
        |> Ash.Changeset.for_update(:mark_sent, %{notification_id: notification_id})
        |> Ash.update!(authorize?: false)

      {:ok, :already_exists} ->
        # Idempotency conflict — notification exists but we couldn't look it up.
        # Mark as sent without linking notification_id.
        receipt
        |> Ash.Changeset.for_update(:mark_sent, %{})
        |> Ash.update!(authorize?: false)

      {:error, :no_user_id} ->
        # Skip receipts for external recipients without user_ids
        receipt
        |> Ash.Changeset.for_update(:skip, %{
          error_message: "In-app notifications require user_id (external recipient)"
        })
        |> Ash.update!(authorize?: false)

      {:error, reason} ->
        receipt
        |> Ash.Changeset.for_update(:mark_failed, %{error_message: inspect(reason)})
        |> Ash.update!(authorize?: false)
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

  @doc """
  The idempotency key for one in-app delivery.

  Shape: `event_id:resource_id:audience:user_id`, or `event_id:audience:user_id`
  when no resource identifies the occurrence. The `audience` segment keeps a
  user who is reachable through two audiences (their own, plus admin) from
  being notified twice for one event.

  `resource_id` is the identity of **the occurrence**, not of the recipient.
  Where it comes from:

    * the channel's `idempotency_source`, naming the key in `data` that says
      which occurrence this is — use it whenever `data` carries more than one
      record with an `:id`;
    * otherwise the first value in `data` carrying a binary `:id`, which is a
      heuristic: with several such values the winner is map iteration order.

  An event that keys on the recipient can only ever be delivered once per
  recipient, for the lifetime of that recipient.
  """
  @spec idempotency_key(map(), map(), String.t()) :: String.t()
  def idempotency_key(channel, context, user_id) do
    case resource_id_for_key(channel, context) do
      nil -> "#{context.event_id}:#{channel.audience}:#{user_id}"
      resource_id -> "#{context.event_id}:#{resource_id}:#{channel.audience}:#{user_id}"
    end
  end

  # The occurrence's identity, not the subject's.
  #
  # `extract_resource_id/1` takes whichever value in `data` happens to carry a
  # binary `:id`. With more than one such value the winner is map iteration
  # order — not something a caller can reason about, and not stable across
  # Elixir versions. An event whose data carries both a recipient and the thing
  # that happened therefore keys on the recipient, so the notification can be
  # delivered exactly once per user for the lifetime of that user.
  #
  # `idempotency_source` lets the channel name the key in `data` that
  # identifies THIS occurrence. Unset, the old heuristic stands.
  defp resource_id_for_key(%{idempotency_source: key}, %{data: data})
       when not is_nil(key) and is_map(data) do
    case Map.get(data, key) do
      %{id: id} when is_binary(id) -> id
      id when is_binary(id) -> id
      _ -> nil
    end
  end

  defp resource_id_for_key(_channel, context), do: extract_resource_id(context)

  # A duplicate must never reach the caller as an exception.
  #
  # `Ash.create` returns `{:error, _}` for a unique violation only when it owns
  # the transaction. Inside an OUTER transaction — an Ash action that dispatches
  # from a hook, say — AshPostgres raises instead, and the raise unwinds the
  # caller's transaction along with any work it had already done. A trigger that
  # stamps its own idempotency flag before dispatching would lose the stamp and
  # re-run forever.
  #
  # So: look first, and still treat a raised conflict as the conflict it is.
  defp create_notification(notification_resource, attrs, idempotency_key) do
    case find_by_idempotency_key(notification_resource, idempotency_key) do
      {:ok, existing} ->
        {:already_exists, existing}

      _ ->
        insert_notification(notification_resource, attrs, idempotency_key)
    end
  end

  defp insert_notification(notification_resource, attrs, idempotency_key) do
    notification_resource
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, notification} -> {:ok, notification}
      {:error, error} -> classify_create_error(notification_resource, error, idempotency_key)
    end
  rescue
    error -> classify_create_error(notification_resource, error, idempotency_key)
  end

  defp classify_create_error(notification_resource, error, idempotency_key) do
    if idempotency_conflict?(error) do
      case find_by_idempotency_key(notification_resource, idempotency_key) do
        {:ok, existing} -> {:already_exists, existing}
        _ -> {:already_exists, :already_exists}
      end
    else
      {:error, error}
    end
  end

  # Look up an existing notification by idempotency key
  defp find_by_idempotency_key(notification_resource, key) do
    require Ash.Query

    notification_resource
    |> Ash.Query.filter(idempotency_key == ^key)
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [notification]} -> {:ok, notification}
      _ -> {:error, :not_found}
    end
  end

  # Check if an Ash error contains a unique constraint violation on idempotency_key.
  # Handles both direct error structs and nested Splode error wrappers.
  defp idempotency_conflict?(error) do
    errors = extract_errors(error)

    Enum.any?(errors, fn
      %{field: :idempotency_key, message: "has already been taken"} ->
        true

      %{private_vars: vars} when is_list(vars) ->
        constraint = Keyword.get(vars, :constraint, "")
        String.contains?(to_string(constraint), "idempotency")

      error_item ->
        # Fallback: check string representation for idempotency constraint violations
        error_str = inspect(error_item)

        String.contains?(error_str, "idempotency_key") and
          String.contains?(error_str, "has already been taken")
    end)
  end

  # Extract flat list of errors from potentially nested Ash/Splode error structures
  defp extract_errors(%{errors: errors}) when is_list(errors) do
    Enum.flat_map(errors, fn
      %{errors: nested} when is_list(nested) -> extract_errors(%{errors: nested})
      error -> [error]
    end)
  end

  defp extract_errors(error), do: [error]
end
