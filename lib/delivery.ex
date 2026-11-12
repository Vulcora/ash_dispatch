defmodule AshDispatch.Delivery do
  @moduledoc """
  The last question before a delivery leaves: may this one really go out?

  Every send point asks it, and it is one function so that the answer — and the
  reason written on the receipt — is the same wherever the delivery happens to
  be sent from:

  - `AshDispatch.Workers.SendEmail`, `SendSMS`, `SendWebhook` — at the top of
    the job, before the receipt is moved to `:sending`;
  - `AshDispatch.Transports.InApp` and `Push` — immediately before the write,
    because they deliver synchronously and have no job.

  Two things can hold a delivery back, and they are asked in this order:

  1. **The recipient's eligibility** (`AshDispatch.EligibleRecipient`) — may
     this person be reached? Asked again here, because a delivery can wait in a
     queue for hours and an account can be closed while it waits.
  2. **The delivery mode** (`AshDispatch.DeliveryMode`) — does this host send at
     all, over this transport, to this recipient?

  The order is the order of the answers a person wants. "The account is closed"
  says something about the world; "this host is in dry run" says something about
  the host. A `:dry_run` receipt therefore reads `delivery_dry_run` only when
  the letter would genuinely have gone out, which is what makes the count of
  those receipts worth anything.

  Each check is inert until the host configures it, so a host that configures
  none of them reaches exactly the same people as before.

  ## The synchronous transports ask less

  `:in_app` and `:push` deliver in the same breath as the dispatch, which has
  just asked the eligibility check for this very receipt. They call
  `mode_verdict/1` rather than `verdict/1`, so a host's check is not run against
  the same recipient twice in the same microsecond.
  """

  alias AshDispatch.DeliveryMode
  alias AshDispatch.EligibleRecipient
  alias AshDispatch.ReceiptStatus

  require Logger

  @doc """
  The full verdict for a receipt about to be sent: the recipient's eligibility,
  then the delivery mode.

  Returns `:send`, or `{:skip, reason}` with the reason to write on the
  receipt.
  """
  @spec verdict(map()) :: :send | {:skip, String.t()}
  def verdict(receipt) do
    with :send <- EligibleRecipient.send_verdict(receipt) do
      mode_verdict(receipt)
    end
  end

  @doc """
  The delivery mode alone — for the transports that deliver synchronously, in
  the same breath as the dispatch.
  """
  @spec mode_verdict(map()) :: :send | {:skip, String.t()}
  def mode_verdict(receipt) do
    DeliveryMode.verdict(Map.get(receipt, :transport), Map.get(receipt, :recipient))
  end

  @doc """
  Records that a delivery was held back: the receipt becomes `:skipped` and
  carries `reason`.

  A hold is a successful outcome, not a failure — nothing was lost, and the
  receipt still holds the letter that would have gone out.

  The update is not allowed to raise. A receipt in a state `:skip` cannot leave
  (a `:failed` one, say, held back by an allow-list that changed between
  attempts) is logged and returned untouched, rather than crashing the job that
  was doing the right thing.
  """
  @spec hold(map(), String.t()) :: map()
  def hold(receipt, reason) when is_binary(reason) do
    Logger.info(
      "Delivery held back for receipt #{Map.get(receipt, :id)} " <>
        "(#{Map.get(receipt, :transport)}): #{reason}"
    )

    case ReceiptStatus.skip(receipt, reason) do
      {:ok, updated} ->
        updated

      {:error, error} ->
        Logger.error(
          "Receipt #{Map.get(receipt, :id)} could not be recorded as held back " <>
            "(#{reason}): #{inspect(error)}"
        )

        receipt
    end
  end
end
