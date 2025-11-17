defmodule AshDispatch.Transports.Email do
  @moduledoc """
  Email transport via Oban jobs.

  Enqueues email delivery jobs for asynchronous sending.

  ## Behavior

  1. Checks user preferences (if event is user_configurable)
  2. Resolves recipients from context
  3. Enqueues Oban jobs for each recipient
  4. Updates receipt status to `:scheduled`

  ## Status Flow

  ```
  pending → scheduled (job enqueued)
          ↘ skipped (user opted out or no recipients)

  Later (in Oban worker):
  scheduled → sending (job started)
           → sent (email delivered)
           ↘ failed (delivery error)
  ```

  ## Delayed Delivery

  Supports delayed delivery via channel's `time` field:

      channel = %Channel{
        transport: :email,
        time: {:in, 300}  # Deliver in 5 minutes
      }

  ## Example

      receipt = %{
        content: %{
          subject: "Order Created",
          from: "orders@example.com",
          html_body: "<h1>Order #1234</h1>",
          text_body: "Order #1234 created"
        }
      }

      Email.deliver(receipt, context, channel, event_config)
      # -> Enqueues Oban job
      # -> Returns {:ok, updated_receipt}
  """

  alias AshDispatch.{Context, Channel}
  alias AshDispatch.Resources.DeliveryReceipt

  require Logger

  @doc """
  Delivers email by enqueueing Oban job.

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

      # Check if any recipients
      if Enum.empty?(recipients) do
        Logger.info("No recipients for email, skipping")

        updated_receipt =
          receipt
          |> Ash.Changeset.for_update(:skip, %{error_message: "no_recipients"})
          |> Ash.update!()

        {:ok, updated_receipt}
      else
        # Enqueue Oban jobs for each recipient
        results =
          Enum.map(recipients, fn recipient ->
            enqueue_email_job(recipient, receipt, context, channel)
          end)

        # Update receipt status
        updated_receipt = update_receipt_status(receipt, results, channel)

        {:ok, updated_receipt}
      end
    end
  rescue
    error ->
      Logger.error("""
      Email transport failed to enqueue jobs
      Event: #{context.event_id}
      Error: #{inspect(error)}
      """)

      {:error, error}
  end

  # Private functions

  defp resolve_recipients(context, channel, event_config) do
    base_recipients =
      case event_config[:module] do
        nil ->
          # Use RecipientResolver for inline events
          resolve_inline_recipients(context, channel)

        module ->
          # Custom event module handles recipients
          module.recipients(context, channel)
      end

    # TODO: Filter by user preferences
    # For now, return all recipients
    base_recipients
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

  defp enqueue_email_job(recipient, receipt, context, channel) do
    # Build job args
    args = %{
      "receipt_id" => receipt.id,
      "recipient_email" => get_recipient_email(recipient),
      "event_id" => context.event_id,
      "subject" => receipt.content[:subject],
      "from" => receipt.content[:from],
      "html_body" => receipt.content[:html_body],
      "text_body" => receipt.content[:text_body]
    }

    # Calculate schedule time
    schedule_in = schedule_seconds(channel)

    # Enqueue Oban job
    job_changeset =
      AshDispatch.Workers.SendEmail.new(args, schedule_in: schedule_in)

    case Oban.insert(job_changeset) do
      {:ok, job} ->
        Logger.debug("Enqueued email job #{job.id} for receipt #{receipt.id}")
        {:ok, job}

      {:error, error} ->
        Logger.error("Failed to enqueue email job: #{inspect(error)}")
        {:error, error}
    end
  end

  defp get_recipient_email(recipient) when is_binary(recipient), do: recipient
  defp get_recipient_email(%{email: email}), do: email
  defp get_recipient_email(recipient), do: to_string(recipient)

  defp schedule_seconds(%Channel{time: {:in, seconds}}), do: seconds
  defp schedule_seconds(_), do: 0

  defp update_receipt_status(receipt, results, _channel) do
    # Check if all jobs enqueued successfully
    all_succeeded =
      Enum.all?(results, fn
        {:ok, _} -> true
        _ -> false
      end)

    # Update receipt via Ash
    if all_succeeded do
      receipt
      |> Ash.Changeset.for_update(:schedule, %{})
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
