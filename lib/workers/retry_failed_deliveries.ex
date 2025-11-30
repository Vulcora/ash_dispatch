defmodule AshDispatch.Workers.RetryFailedDeliveries do
  @moduledoc """
  Cron worker that automatically retries failed delivery receipts.

  Runs periodically via Oban.Plugins.Cron. Queries for delivery receipts that:
  - Have status == :failed (temporary failure)
  - Have retry_count < max_retries (default: 5)
  - Either haven't been retried yet OR last retry was > retry_delay_minutes ago
  - Are not permanently failed (:failed_permanent)

  For each eligible receipt:
  1. Re-enqueues appropriate Oban worker (SendEmail for now)
  2. Updates receipt status to :scheduled
  3. Increments retry_count
  4. Sets last_retry_at timestamp

  If a receipt has hit max_retries, it will be marked as :failed_permanent by the SendEmail
  worker on the final attempt.

  ## Configuration

  Configure retry behavior:

      config :ash_dispatch,
        max_retries: 5,              # Max retry attempts before permanent failure
        retry_delay_minutes: 15      # Minutes to wait between retries

  ## Scheduling

  Add to Oban cron config:

      config :my_app, Oban,
        plugins: [
          {Oban.Plugins.Cron,
           crontab: [
             # Retry failed deliveries every 15 minutes
             {"*/15 * * * *", AshDispatch.Workers.RetryFailedDeliveries}
           ]}
        ]

  ## Exponential Backoff

  The retry delay is constant (15 minutes by default), but you can implement
  exponential backoff by checking retry_count in the worker:

      # Custom delay based on retry count
      delay_minutes = retry_delay_minutes * (2 ** retry_count)

  ## Example Output

      [info] RetryFailedDeliveries: Found 3 failed deliveries to retry
      [info] Retried delivery: receipt_id=abc123, event=order.created, transport=email, retry_count=2
      [info] Retry results: 3 succeeded, 0 failed

  ## Monitoring

  Track retry metrics in your monitoring system:
  - Number of failed receipts retried per run
  - Success/failure rate of retries
  - Receipts hitting max_retries (becoming :failed_permanent)
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1

  alias AshDispatch.Config
  alias AshDispatch.Workers.SendEmail

  require Ash.Query
  require Logger

  @default_max_retries 5
  @default_retry_delay_minutes 15

  @doc """
  Processes the retry job.

  Queries for eligible failed receipts and retries them.

  ## Returns

  - `:ok` on success (even if individual retries fail)
  - `{:error, reason}` if the query itself fails
  """
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    max_retries = get_config(:max_retries, @default_max_retries)
    retry_delay_minutes = get_config(:retry_delay_minutes, @default_retry_delay_minutes)

    # Calculate cutoff time (don't retry if last attempt was too recent)
    cutoff_time = DateTime.add(DateTime.utc_now(), -retry_delay_minutes * 60, :second)

    Logger.info(
      "RetryFailedDeliveries: Starting retry job (max_retries=#{max_retries}, delay=#{retry_delay_minutes}m)"
    )

    # Query for eligible failed receipts
    query =
      Config.delivery_receipt_resource()
      |> Ash.Query.filter(status == :failed)
      |> Ash.Query.filter(retry_count < ^max_retries)
      |> Ash.Query.filter(is_nil(last_retry_at) or last_retry_at < ^cutoff_time)
      |> Ash.Query.limit(100)
      # Oldest failures first
      |> Ash.Query.sort(inserted_at: :asc)

    case Ash.read(query, authorize?: false) do
      {:ok, receipts} ->
        count = length(receipts)

        if count > 0 do
          Logger.info("RetryFailedDeliveries: Found #{count} failed deliveries to retry")

          results =
            Enum.map(receipts, fn receipt ->
              retry_receipt(receipt, max_retries)
            end)

          succeeded = Enum.count(results, &(&1 == :ok))
          failed = Enum.count(results, &(&1 != :ok))

          Logger.info(
            "RetryFailedDeliveries: Retry results: #{succeeded} succeeded, #{failed} failed"
          )
        else
          Logger.debug("RetryFailedDeliveries: No failed deliveries to retry")
        end

        :ok

      {:error, reason} ->
        Logger.error(
          "RetryFailedDeliveries: Failed to query for failed deliveries: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Retry a single failed delivery receipt.

  Re-enqueues the appropriate worker based on transport and updates receipt state.

  ## Parameters

  - `receipt` - DeliveryReceipt struct to retry
  - `max_retries` - Maximum number of retries allowed

  ## Returns

  - `:ok` on success
  - `{:error, reason}` on failure
  """
  def retry_receipt(%{__struct__: _} = receipt, max_retries) do
    # Check if this will be the final retry
    next_retry_count = (receipt.retry_count || 0) + 1
    is_final_retry = next_retry_count >= max_retries

    case enqueue_worker(receipt, is_final_retry) do
      {:ok, _job} ->
        # Update receipt: status → :scheduled, increment retry_count, set last_retry_at
        case receipt
             |> Ash.Changeset.for_update(:retry, %{})
             |> Ash.update(authorize?: false) do
          {:ok, updated_receipt} ->
            log_level = if is_final_retry, do: :warning, else: :info

            Logger.log(
              log_level,
              "RetryFailedDeliveries: Retried delivery: receipt_id=#{receipt.id}, event=#{receipt.event_id}, transport=#{receipt.transport}, retry_count=#{updated_receipt.retry_count}#{if is_final_retry, do: " (FINAL RETRY)", else: ""}"
            )

            :ok

          {:error, reason} ->
            Logger.error(
              "RetryFailedDeliveries: Failed to update receipt after retry: receipt_id=#{receipt.id}, reason=#{inspect(reason)}"
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error(
          "RetryFailedDeliveries: Failed to enqueue retry job: receipt_id=#{receipt.id}, transport=#{receipt.transport}, reason=#{inspect(reason)}"
        )

        # If we can't enqueue, mark as failed_permanent after max retries
        if (receipt.retry_count || 0) >= max_retries - 1 do
          mark_failed_permanent(
            receipt,
            "Failed to enqueue retry after #{max_retries} attempts: #{inspect(reason)}"
          )
        end

        {:error, reason}
    end
  end

  # Private functions

  defp get_config(key, default) do
    # These are worker-specific config options not in Config module
    Application.get_env(:ash_dispatch, key, default)
  end

  defp enqueue_worker(%{transport: :email} = receipt, _is_final_retry) do
    # For email transport, use SendEmail worker with receipt_id
    # The worker will fetch the receipt and use its stored content
    %{receipt_id: receipt.id}
    |> SendEmail.new()
    |> Oban.insert()
  end

  defp enqueue_worker(%{transport: transport} = receipt, _is_final_retry) do
    # For other transports, log and skip for now
    # Future: Add Discord, Slack, SMS workers as they're implemented
    Logger.warning(
      "RetryFailedDeliveries: Retry not yet implemented for transport: #{transport}, receipt_id=#{receipt.id}"
    )

    {:error, :transport_not_supported}
  end

  defp mark_failed_permanent(receipt, error_message) do
    Logger.error(
      "RetryFailedDeliveries: Marking receipt as permanently failed: receipt_id=#{receipt.id}, error=#{error_message}"
    )

    receipt
    |> Ash.Changeset.for_update(:mark_failed_permanent, %{error_message: error_message})
    |> Ash.update(authorize?: false)
    |> case do
      {:ok, _updated} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "RetryFailedDeliveries: Failed to mark receipt as permanently failed: receipt_id=#{receipt.id}, reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end
end
