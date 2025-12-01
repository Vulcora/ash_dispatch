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

  alias AshDispatch.Channel
  alias AshDispatch.Config

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
      # Receipt now corresponds to a single recipient (user_id and recipient in receipt)
      # Enqueue one Oban job for this receipt
      result = enqueue_email_job_for_receipt(receipt, context, channel)

      # Update receipt status with oban_job_id
      updated_receipt = update_receipt_with_job(receipt, result, channel)

      {:ok, updated_receipt}
    end
  rescue
    error ->
      Logger.error("""
      Email transport failed to enqueue job
      Event: #{context.event_id}
      Error: #{inspect(error)}
      """)

      {:error, error}
  end

  # Private functions

  # Enqueue Oban job for the receipt (one receipt = one recipient now)
  defp enqueue_email_job_for_receipt(receipt, context, channel) do
    # Build job args from receipt (which now has all recipient info)
    from = get_from_field(receipt)

    args = %{
      "receipt_id" => receipt.id,
      # Receipt already has recipient email
      "recipient_email" => receipt.recipient,
      "event_id" => context.event_id,
      "subject" => receipt.subject,
      "from" => from,
      "html_body" => receipt.body_html,
      "text_body" => receipt.body_text
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

  # Update receipt with oban_job_id and mark as scheduled
  defp update_receipt_with_job(receipt, result, _channel) do
    case result do
      {:ok, job} ->
        receipt
        |> Ash.Changeset.for_update(:schedule, %{oban_job_id: job.id})
        |> Ash.update!()

      {:error, reason} ->
        receipt
        |> Ash.Changeset.for_update(:mark_failed, %{error_message: inspect(reason)})
        |> Ash.update!()
    end
  end

  defp get_from_field(receipt) do
    cond do
      # From field stored as map with name/email (from event module)
      is_map(receipt.content[:from]) ->
        receipt.content[:from]

      # From field is a tuple {name, email} - convert to map for JSON serialization
      is_tuple(receipt.content[:from]) ->
        {name, email} = receipt.content[:from]
        %{"name" => name, "email" => email}

      # From field is a string email address
      is_binary(receipt.content[:from]) ->
        receipt.content[:from]

      # Fallback to configured default
      true ->
        %{"name" => Config.default_from_name(), "email" => Config.default_from_email()}
    end
  end

  defp schedule_seconds(%Channel{time: {:in, seconds}}), do: seconds
  defp schedule_seconds(_), do: 0
end
