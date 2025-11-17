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

  alias AshDispatch.{Context, Channel}
  alias AshDispatch.Resources.{DeliveryReceipt, Notification}

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
      # Resolve recipients
      recipients = resolve_recipients(context, channel, event_config)

      # Create notifications for each recipient
      results =
        Enum.map(recipients, fn recipient ->
          create_notification_for_recipient(recipient, receipt, context)
        end)

      # Update receipt status based on results
      updated_receipt = update_receipt_status(receipt, results)

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

  # Private functions

  defp resolve_recipients(context, channel, event_config) do
    case event_config[:module] do
      nil ->
        # Inline config - resolve from context based on audience
        resolve_inline_recipients(context, channel)

      module ->
        # Use callback module
        module.recipients(context, channel)
    end
  end

  defp resolve_inline_recipients(context, channel) do
    # Delegate to RecipientResolver
    opts = build_resolver_opts(channel)
    AshDispatch.RecipientResolver.resolve(channel.audience, context, opts)
  end

  defp build_resolver_opts(channel) do
    # Extract team name from channel if present
    case Map.get(channel, :team) do
      nil -> []
      team -> [team: team]
    end
  end

  defp create_notification_for_recipient(recipient, receipt, context) do
    # TODO: Check user preferences
    # For now, always create notification

    notification_attrs = %{
      user_id: get_user_id(recipient),
      title: receipt.content[:title],
      message: receipt.content[:message],
      action_url: receipt.content[:action_url],
      notification_type: receipt.content[:notification_type] || :info,
      event_id: context.event_id
    }

    # Create Notification record via Ash
    case Notification
         |> Ash.Changeset.for_create(:create, notification_attrs)
         |> Ash.create() do
      {:ok, notification} ->
        Logger.debug("""
        Created in-app notification:
        User: #{notification.user_id}
        Title: #{notification.title}
        Message: #{notification.message}
        """)

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

  defp get_user_id(recipient) when is_binary(recipient), do: recipient
  defp get_user_id(%{id: id}), do: id
  defp get_user_id(recipient), do: to_string(recipient)

  defp update_receipt_status(receipt, results) do
    # Check if all notifications succeeded
    all_succeeded =
      Enum.all?(results, fn
        {:ok, _} -> true
        _ -> false
      end)

    # Update receipt via Ash
    if all_succeeded do
      receipt
      |> Ash.Changeset.for_update(:mark_sent, %{})
      |> Ash.update!()
    else
      # Find first error
      error_message =
        results
        |> Enum.find_value(fn
          {:error, reason} -> inspect(reason)
          _ -> nil
        end)

      receipt
      |> Ash.Changeset.for_update(:mark_failed, %{error_message: error_message})
      |> Ash.update!()
    end
  end
end
