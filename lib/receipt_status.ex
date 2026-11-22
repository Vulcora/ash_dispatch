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

  alias AshDispatch.Tenancy

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
    |> changeset(:mark_sending)
    |> Ash.update(authorize?: false)
    |> remember(receipt)
  end

  @doc """
  Reclaims a receipt this job's own earlier attempt left in `:sending`
  (`:sending` → `:sending`, through the `:resume_sending` action).

  Not a mutex: `claim/2` decides when resuming is right. Use that.

  `{:error, :unsupported}` for a receipt resource built before 0.9.4, which
  has no `:resume_sending` action.
  """
  @spec resume_sending(struct()) :: {:ok, struct()} | {:error, term()}
  def resume_sending(receipt) do
    if resume_supported?(receipt) do
      receipt
      |> changeset(:resume_sending)
      |> Ash.update(authorize?: false)
      |> remember(receipt)
    else
      {:error, :unsupported}
    end
  end

  @doc """
  Whether `receipt`'s resource has the `:resume_sending` action at all.

  `false` for every receipt resource built before 0.9.4. Public so a host can
  tell "this release cannot reclaim an interrupted send" from "it chose not
  to".
  """
  @spec resume_supported?(struct()) :: boolean()
  def resume_supported?(receipt) do
    resource = receipt.__struct__

    Ash.Resource.Info.resource?(resource) and
      not is_nil(Ash.Resource.Info.action(resource, :resume_sending))
  rescue
    _ -> false
  end

  @doc """
  Claims a receipt for THIS delivery attempt, which is what a send worker
  wants rather than `mark_sending/1` on its own.

  Three answers:

    * `{:ok, receipt}` — the receipt is `:sending` and yours. Deliver.
    * `:duplicate` — it is in a state `:mark_sending` cannot leave, which
      means another job has it. Complete as a success; nothing was lost.
    * `{:error, reason}` — the update failed for some other reason. Let Oban
      retry.

  ## Why a receipt already in `:sending` is not simply refused

  `mark_sending`'s source list has never included `:sending`, and that IS the
  mutex: of two jobs for one receipt the loser is told "no matching
  transition". But the same refusal meets a job whose OWN earlier attempt
  marked the receipt `:sending` and then stopped without a result — the node
  went down, or Oban's lifeline put the job back. Reading that as "somebody
  else has this" completes the job green on a letter nobody sent, and leaves
  the receipt in `:sending`, where no sweep looked before 0.9.4.

  So: a receipt in `:sending` is reclaimed (`resume_sending/1`) when this is
  not the job's first attempt, and treated as another job's work when it is.
  `:attempt` is `Oban.Job`'s own counter; without one, every attempt is a
  first attempt, which is the conservative reading.

  ## Options

  - `:attempt` - this job's attempt number (`%Oban.Job{}.attempt`)
  - `:resume` - `true` forces the reclaim, `false` forbids it, whatever the
    attempt. For a caller that knows better than the attempt counter does
  """
  @spec claim(struct(), keyword()) :: {:ok, struct()} | :duplicate | {:error, term()}
  def claim(receipt, opts \\ []) do
    if Map.get(receipt, :status) == :sending and resume?(opts) do
      case resume_sending(receipt) do
        {:ok, updated} ->
          {:ok, updated}

        # TWO causes, and only these two, mean "deliver from the receipt as it
        # stands": a receipt resource from before 0.9.4, which has no
        # `:resume_sending` action at all, and a host that narrowed the
        # transition so `:sending` is not a source for it. In both the receipt
        # is already `:sending` and this attempt owns it, which is what 0.9.2
        # did for email before the decision had a name.
        #
        # Anything else — a validation the host added, a database that would
        # not take the write, a tenant that could not be resolved — is a
        # FAILURE, and answering `{:ok, receipt}` to it would send the letter
        # with the receipt left behind saying something else. It propagates,
        # and Oban retries without sending.
        {:error, :unsupported} ->
          {:ok, receipt}

        {:error, reason} = error ->
          if no_transition?(reason) do
            {:ok, receipt}
          else
            error
          end
      end
    else
      claim_fresh(receipt)
    end
  end

  # `AshStateMachine` reports a refused transition as this error inside an
  # `Ash.Error.Invalid`; a host that narrowed `:resume_sending` is the case it
  # stands for here.
  defp no_transition?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, &match?(%AshStateMachine.Errors.NoMatchingTransition{}, &1))
  end

  defp no_transition?(_reason), do: false

  defp claim_fresh(receipt) do
    case mark_sending(receipt) do
      {:ok, updated} ->
        {:ok, updated}

      {:error, %Ash.Error.Invalid{errors: errors}} = error ->
        if Enum.any?(errors, &match?(%AshStateMachine.Errors.NoMatchingTransition{}, &1)) do
          :duplicate
        else
          error
        end

      error ->
        error
    end
  end

  defp resume?(opts) do
    case Keyword.fetch(opts, :resume) do
      {:ok, resume} when is_boolean(resume) -> resume
      _ -> is_integer(Keyword.get(opts, :attempt)) and Keyword.get(opts, :attempt) > 1
    end
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
    |> changeset(:mark_sent, %{
      provider_id: provider_response[:id] || provider_response["id"],
      provider_response: provider_response
    })
    |> Ash.update!(authorize?: false)
    |> remember(receipt)
  end

  def mark_sent(receipt, _provider_response) do
    receipt
    |> changeset(:mark_sent)
    |> Ash.update!(authorize?: false)
    |> remember(receipt)
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
    |> changeset(:mark_failed, %{error_message: error_message})
    |> Ash.update!(authorize?: false)
    |> remember(receipt)
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
    |> changeset(:skip, %{error_message: reason})
    |> Ash.update!(authorize?: false)
    |> remember(receipt)
  end

  @doc """
  `mark_skipped/2` without the bang: `{:ok, receipt}` or `{:error, reason}`.

  For a caller that must not be taken down by a receipt in a state `:skip`
  cannot leave — `AshDispatch.Delivery.hold/2` records a held-back delivery
  from paths where the receipt may be `:failed` or already terminal.
  """
  @spec skip(struct(), String.t()) :: {:ok, struct()} | {:error, term()}
  def skip(receipt, reason) when is_binary(reason) do
    receipt
    |> changeset(:skip, %{error_message: reason})
    |> Ash.update(authorize?: false)
    |> remember(receipt)
  end

  @doc """
  Records which Oban job belongs to this receipt, without a transition.

  For a transport that has to mark the receipt `:scheduled` BEFORE inserting
  the job — the webhook, Slack and Discord transports do, because an inline
  job runs inside `Oban.insert/1` and would race the transition — so the job
  id can only be written afterwards. It goes through the primary `:update`
  action, which accepts `:oban_job_id` and moves no state, so a receipt the
  job has already carried to `:sent` is not disturbed.

  Without the id the stranded sweep has no job to look up for that receipt and
  decides on age alone (`AshDispatch.Workers.Stranded`), which is the gap this
  closes.

  Never raises: a receipt that could not be given its job id is a receipt the
  sweep is more careful about, not a failed delivery.
  """
  @spec put_oban_job_id(struct(), integer() | nil) :: struct()
  def put_oban_job_id(receipt, nil), do: receipt

  def put_oban_job_id(receipt, job_id) do
    receipt
    |> changeset(:update, %{oban_job_id: job_id})
    |> Ash.update(authorize?: false)
    |> case do
      {:ok, updated} -> Tenancy.remember(updated, Tenancy.of(receipt))
      {:error, _reason} -> receipt
    end
  rescue
    _ -> receipt
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
    |> changeset(:schedule, attrs)
    |> Ash.update!(authorize?: false)
    |> remember(receipt)
  end

  @doc """
  Holds an email receipt for a digest (`:pending` → `:batched`), storing what
  the digest needs under `content["digest"]`. See `AshDispatch.Digest`.
  """
  @spec batch(struct(), map()) :: {:ok, struct()} | {:error, term()}
  def batch(receipt, digest) when is_map(digest) do
    receipt
    |> changeset(:batch, %{digest: digest})
    |> Ash.update(authorize?: false)
    |> remember(receipt)
  end

  @doc """
  Sends a batched receipt on its own after all (`:batched` → `:scheduled`):
  it was the only email in its digest window.
  """
  @spec release(struct(), keyword()) :: {:ok, struct()} | {:error, term()}
  def release(receipt, opts \\ []) do
    attrs =
      case Keyword.get(opts, :oban_job_id) do
        nil -> %{}
        job_id -> %{oban_job_id: job_id}
      end

    receipt
    |> changeset(:release, attrs)
    |> Ash.update(authorize?: false)
    |> remember(receipt)
  end

  @doc """
  Marks a batched receipt as delivered inside the digest `digest_receipt_id`
  (`:batched` → `:digested`). Fails when the receipt is no longer batched,
  which is what keeps one email out of two digests.
  """
  @spec mark_digested(struct(), term()) :: {:ok, struct()} | {:error, term()}
  def mark_digested(receipt, digest_receipt_id) do
    receipt
    |> changeset(:mark_digested, %{digest_receipt_id: to_string(digest_receipt_id)})
    |> Ash.update(authorize?: false)
    |> remember(receipt)
  end

  @doc """
  Refuses to send a receipt: it ends in "failed_permanent" whatever its status,
  through "failed" from "pending", which has no direct transition.
  """
  @spec refuse(struct(), String.t()) :: struct()
  def refuse(%{status: :pending} = receipt, reason) when is_binary(reason) do
    receipt |> mark_failed(reason) |> mark_failed_permanent(reason)
  end

  def refuse(receipt, reason) when is_binary(reason) do
    mark_failed_permanent(receipt, reason)
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
    |> changeset(:mark_failed_permanent, %{error_message: error_message})
    |> Ash.update!(authorize?: false)
    |> remember(receipt)
  end

  # Every transition in this module goes through these two, which is the whole
  # of its tenancy: the update happens in the schema the receipt was read from,
  # and the receipt that comes back still knows which one that was, so the next
  # transition lands in the same place. "The tenant came from the receipt we
  # are updating" is then true by construction rather than by discipline, and
  # none of the eight functions above needed a new argument.
  defp changeset(receipt, action, attrs \\ %{}) do
    Tenancy.changeset_for_update(receipt, action, attrs)
  end

  defp remember({:ok, updated}, original),
    do: {:ok, Tenancy.remember(updated, Tenancy.of(original))}

  defp remember({:error, _} = error, _original), do: error
  defp remember(%{} = updated, original), do: Tenancy.remember(updated, Tenancy.of(original))
end
