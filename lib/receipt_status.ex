defmodule AshDispatch.ReceiptStatus do
  @moduledoc """
  Centralized receipt status management for AshDispatch workers.

  This module provides consistent receipt status updates across all delivery
  workers (email, webhook, etc.), ensuring uniform behavior and reducing
  code duplication.

  ## Why This Exists

  Receipt status updates were duplicated across multiple workers:
  - `AshDispatch.Workers.SendEmail`
  - `AshDispatch.Workers.SendWebhook`

  Each had identical `mark_sending/1`, `mark_sent/2`, `mark_failed/2` functions.
  This module consolidates them into a single source of truth.

  ## Status Flow

  ```
  pending → sending → sent
                    ↘ failed → failed_permanent (after max retries)
          ↘ scheduled (for async transports)
          ↘ skipped (user opted out, missing config, etc.)
  ```

  ## Usage

      alias AshDispatch.ReceiptStatus

      # In a worker
      def perform(%Oban.Job{args: args}) do
        with {:ok, receipt} <- get_receipt(args["receipt_id"]),
             {:ok, receipt} <- ReceiptStatus.mark_sending(receipt),
             {:ok, response} <- do_delivery(receipt) do
          ReceiptStatus.mark_sent(receipt, response)
          :ok
        else
          {:error, reason} ->
            ReceiptStatus.mark_failed(receipt, reason)
            {:error, reason}
        end
      end
  """

  @doc """
  Marks a receipt as "sending" (delivery in progress).

  This is called at the start of a delivery attempt.

  ## Returns

  - `{:ok, updated_receipt}` on success
  - `{:error, changeset}` on failure
  """
  @spec mark_sending(struct()) :: {:ok, struct()} | {:error, Ash.Changeset.t()}
  def mark_sending(receipt) do
    receipt
    |> Ash.Changeset.for_update(:mark_sending, %{})
    |> Ash.update()
  end

  @doc """
  Marks a receipt as "sent" (delivery successful).

  Stores provider response metadata for tracking and debugging.

  ## Parameters

  - `receipt` - The delivery receipt struct
  - `provider_response` - Map with provider details, e.g., `%{id: "msg_123", ...}`

  ## Returns

  The updated receipt (raises on failure since this is critical).
  """
  @spec mark_sent(struct(), map()) :: struct()
  def mark_sent(receipt, provider_response) when is_map(provider_response) do
    receipt
    |> Ash.Changeset.for_update(:mark_sent, %{
      provider_id: provider_response[:id] || provider_response["id"],
      provider_response: provider_response
    })
    |> Ash.update!()
  end

  def mark_sent(receipt, _provider_response) do
    receipt
    |> Ash.Changeset.for_update(:mark_sent, %{})
    |> Ash.update!()
  end

  @doc """
  Marks a receipt as "failed" (delivery failed, may retry).

  ## Parameters

  - `receipt` - The delivery receipt struct
  - `reason` - Error reason (will be converted to string via `inspect/1`)

  ## Returns

  The updated receipt (raises on failure since this is critical).
  """
  @spec mark_failed(struct(), any()) :: struct()
  def mark_failed(receipt, reason) do
    error_message =
      case reason do
        msg when is_binary(msg) -> msg
        other -> inspect(other)
      end

    receipt
    |> Ash.Changeset.for_update(:mark_failed, %{error_message: error_message})
    |> Ash.update!()
  end

  @doc """
  Marks a receipt as "skipped" (intentionally not sent).

  Used when:
  - User opted out of notifications
  - Required configuration is missing
  - Transport is not implemented

  ## Parameters

  - `receipt` - The delivery receipt struct
  - `reason` - Reason for skipping (string)

  ## Returns

  The updated receipt (raises on failure since this is critical).
  """
  @spec mark_skipped(struct(), String.t()) :: struct()
  def mark_skipped(receipt, reason) when is_binary(reason) do
    receipt
    |> Ash.Changeset.for_update(:skip, %{error_message: reason})
    |> Ash.update!()
  end

  @doc """
  Marks a receipt as "scheduled" (job enqueued for later delivery).

  Optionally stores the Oban job ID for tracking.

  ## Parameters

  - `receipt` - The delivery receipt struct
  - `opts` - Options keyword list
    - `:oban_job_id` - The Oban job ID (optional)

  ## Returns

  The updated receipt (raises on failure since this is critical).
  """
  @spec mark_scheduled(struct(), keyword()) :: struct()
  def mark_scheduled(receipt, opts \\ []) do
    attrs =
      case Keyword.get(opts, :oban_job_id) do
        nil -> %{}
        job_id -> %{oban_job_id: job_id}
      end

    receipt
    |> Ash.Changeset.for_update(:schedule, attrs)
    |> Ash.update!()
  end

  @doc """
  Marks a receipt as "failed_permanent" (no more retries).

  Used by retry worker when max retries exceeded.

  ## Parameters

  - `receipt` - The delivery receipt struct
  - `error_message` - Final error message

  ## Returns

  The updated receipt (raises on failure since this is critical).
  """
  @spec mark_failed_permanent(struct(), String.t()) :: struct()
  def mark_failed_permanent(receipt, error_message) when is_binary(error_message) do
    receipt
    |> Ash.Changeset.for_update(:mark_failed_permanent, %{error_message: error_message})
    |> Ash.update!()
  end
end
