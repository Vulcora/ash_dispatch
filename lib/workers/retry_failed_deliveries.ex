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
  alias AshDispatch.Workers.Stranded

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

    # Receipts stranded in :scheduled are swept FIRST, so anything rescued in
    # this pass is already `:failed` when the query below runs and gets its
    # retry immediately instead of waiting a further cycle.
    sweep_stranded()

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
  Sweeps receipts stranded in `:scheduled`.

  `:scheduled` promises that a job is coming. Nothing ever checked whether one
  actually was, and this sweep is that check. See
  `AshDispatch.Workers.Stranded` for why the three outcomes are what they are
  — the short version is that the grace period stops us racing a live job,
  and the staleness ceiling stops us delivering a months-old mail to someone
  who has long since moved on.

  Errors are logged and swallowed: a sweep that cannot read must not take the
  ordinary retry pass down with it.
  """
  @spec sweep_stranded() :: :ok
  def sweep_stranded do
    stuck_after =
      get_config(:stranded_stuck_after_minutes, Stranded.default_stuck_after_minutes())

    stale_after = get_config(:stranded_stale_after_hours, Stranded.default_stale_after_hours())

    query =
      Config.delivery_receipt_resource()
      |> Ash.Query.filter(status == :scheduled)
      |> Ash.Query.limit(100)
      |> Ash.Query.sort(inserted_at: :asc)

    case Ash.read(query, authorize?: false) do
      {:ok, []} ->
        :ok

      {:ok, receipts} ->
        opts = [stuck_after_minutes: stuck_after, stale_after_hours: stale_after]

        tally =
          receipts
          |> Enum.map(&handle_stranded(&1, opts))
          |> Enum.frequencies()

        if Map.get(tally, :leave, 0) != length(receipts) do
          Logger.warning(
            "RetryFailedDeliveries: stranded sweep — " <>
              "#{Map.get(tally, :rescue, 0)} rescued, #{Map.get(tally, :close, 0)} closed, " <>
              "#{Map.get(tally, :leave, 0)} still in flight"
          )
        end

        :ok

      {:error, reason} ->
        Logger.error("RetryFailedDeliveries: stranded sweep query failed: #{inspect(reason)}")
        :ok
    end
  rescue
    error ->
      Logger.error("RetryFailedDeliveries: stranded sweep crashed: #{Exception.message(error)}")
      :ok
  end

  defp handle_stranded(receipt, opts) do
    reference = Map.get(receipt, :updated_at) || Map.get(receipt, :inserted_at)

    case Stranded.action(reference, opts) do
      :leave ->
        :leave

      :rescue ->
        # Moved to :failed so the machinery that already exists takes over.
        # No second send path, no new terminal state.
        mark_failed(receipt, "Stranded in :scheduled with no live job — returned for retry.")
        :rescue

      :close ->
        mark_failed_permanent(receipt, Stranded.close_reason(reference, opts))
        :close
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
  # ORDERING MATTERS: the receipt must be moved to `:scheduled` BEFORE the
  # Oban job is enqueued.
  #
  # This used to enqueue first. Oban picks a job up within milliseconds, so
  # the worker regularly ran while the receipt was still `:failed`.
  # `mark_sending` had no transition from `:failed`, so the worker hit its
  # no-matching-transition branch, logged "likely duplicate job" and returned
  # `:ok`. The job completed green, no mail was sent, and the receipt was then
  # set to `:scheduled` — a state nothing monitors and that this worker
  # (which queries `status == :failed`) never picks up again.
  #
  # Every retry was a coin flip. In one production deployment this had
  # silently dropped 17 emails over eight months — every enqueued job showed
  # `completed` and zero receipts showed `failed`, so nothing surfaced
  # anywhere.
  def retry_receipt(%{__struct__: _} = receipt, max_retries) do
    # Check if this will be the final retry
    next_retry_count = (receipt.retry_count || 0) + 1
    is_final_retry = next_retry_count >= max_retries

    case receipt
         |> Ash.Changeset.for_update(:retry, %{})
         |> Ash.update(authorize?: false) do
      {:ok, updated_receipt} ->
        case enqueue_worker(updated_receipt, is_final_retry) do
          {:ok, :already_handled} ->
            # Transport handled the full lifecycle synchronously (e.g. in_app
            # retry) — the receipt has already been marked :sent.
            Logger.info(
              "RetryFailedDeliveries: Retried delivery (direct): receipt_id=#{receipt.id}, event=#{receipt.event_id}, transport=#{receipt.transport}"
            )

            :ok

          {:ok, _job} ->
            log_level = if is_final_retry, do: :warning, else: :info

            Logger.log(
              log_level,
              "RetryFailedDeliveries: Retried delivery: receipt_id=#{receipt.id}, event=#{receipt.event_id}, transport=#{receipt.transport}, retry_count=#{updated_receipt.retry_count}#{if is_final_retry, do: " (FINAL RETRY)", else: ""}"
            )

            :ok

          {:error, reason} ->
            Logger.error(
              "RetryFailedDeliveries: Failed to enqueue retry job: receipt_id=#{receipt.id}, transport=#{receipt.transport}, reason=#{inspect(reason)}"
            )

            # The receipt is now `:scheduled` with no job behind it — exactly
            # the invisible state this function exists to avoid. Put it back
            # to `:failed` so the next cron run sees it, or retire it for good
            # once the retries are spent.
            if (receipt.retry_count || 0) >= max_retries - 1 do
              mark_failed_permanent(
                updated_receipt,
                "Failed to enqueue retry after #{max_retries} attempts: #{inspect(reason)}"
              )
            else
              mark_failed(updated_receipt, "Failed to enqueue retry job: #{inspect(reason)}")
            end

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error(
          "RetryFailedDeliveries: Failed to update receipt before retry: receipt_id=#{receipt.id}, reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # Private functions

  defp get_config(key, default) do
    # These are worker-specific config options not in Config module
    Application.get_env(:ash_dispatch, key, default)
  end

  defp enqueue_worker(%{transport: :email} = receipt, _is_final_retry) do
    # For email transport, use SendEmail worker with receipt_id.
    # The worker fetches the receipt and uses its stored content;
    # new_for_receipt/1 carries the original job's attachments forward
    # (they exist only in job args, not on the receipt).
    receipt
    |> SendEmail.new_for_receipt()
    |> Oban.insert()
  end

  defp enqueue_worker(%{transport: :in_app} = receipt, _is_final_retry) do
    # In-app delivery is synchronous — retry directly instead of via Oban.
    # retry_from_receipt handles the full lifecycle (create notification + mark_sent),
    # so return :already_handled to skip the caller's receipt status update.
    case AshDispatch.Transports.InApp.retry_from_receipt(receipt) do
      :ok -> {:ok, :already_handled}
      error -> error
    end
  end

  defp enqueue_worker(%{transport: transport} = receipt, _is_final_retry) do
    # For other transports, log and skip for now
    # Future: Add Discord, Slack, SMS workers as they're implemented
    Logger.warning(
      "RetryFailedDeliveries: Retry not yet implemented for transport: #{transport}, receipt_id=#{receipt.id}"
    )

    {:error, :transport_not_supported}
  end

  defp mark_failed(receipt, error_message) do
    receipt
    |> Ash.Changeset.for_update(:mark_failed, %{error_message: error_message})
    |> Ash.update(authorize?: false)
    |> case do
      {:ok, _updated} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "RetryFailedDeliveries: Failed to mark receipt back as failed: receipt_id=#{receipt.id}, reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
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
