defmodule AshDispatch.Workers.Stranded do
  @moduledoc """
  What to do with a receipt that is stuck in `:scheduled`.

  `:scheduled` means "a job is coming". Nothing has ever checked whether one
  actually is. A receipt whose job died, was pruned, or never got enqueued
  sits there forever: the retry sweep only queries `status == :failed`, so it
  never looks, and no surface counts it. One production deployment carried
  **17 such receipts across six months** — four order confirmations (two of
  them to a customer, not staff), four reseller applications and nine product
  announcements. Every one of them showed a 429 from the mail provider, was
  moved to `:scheduled` by a retry, and was then never seen again.

  The decision has three outcomes, and the middle one is the whole reason the
  other two need care:

    * `:leave` — younger than the grace period. `:scheduled` is a legitimate
      transient state; a receipt enqueued a minute ago is not stranded, it is
      working. Acting here would fight the normal path and could double-send.

    * `:rescue` — past the grace period and still worth sending. Moved to
      `:failed`, which hands it to machinery that already exists: the retry
      sweep picks up `:failed`, re-enqueues it, and `SendEmail` eventually
      marks it `:failed_permanent` if the attempts run out. No new terminal
      state, no second send path.

    * `:close` — past the staleness ceiling. NOT sent. An order confirmation
      for an order completed in January, delivered in August, is worse than
      silence: the recipient has to work out whether something went wrong.
      Marked `:failed_permanent` with a reason so the books stop lying, since
      an invisible debt is the actual defect here — not the unsent mail.

  Both bounds are configurable, and the ceiling is deliberately generous. An
  app that genuinely wants old mail delivered can raise it; the default
  refuses to make that choice on someone's behalf.
  """

  @default_stuck_after_minutes 30
  @default_stale_after_hours 24

  @typedoc "What should happen to a receipt sitting in `:scheduled`."
  @type action :: :leave | :rescue | :close

  @doc """
  Decides the fate of one stranded receipt.

  `age_reference` is when the receipt last moved — `updated_at` where the
  resource keeps one, otherwise `inserted_at`. Using the last movement rather
  than creation matters: a receipt that was retried an hour ago is an hour
  stranded, not however old its first attempt was.

  Both bounds are in the same unit the config uses (minutes and hours), and
  are converted here so callers never have to.
  """
  @spec action(DateTime.t() | NaiveDateTime.t(), keyword()) :: action()
  def action(age_reference, opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    stuck_after = Keyword.get(opts, :stuck_after_minutes, @default_stuck_after_minutes) * 60
    stale_after = Keyword.get(opts, :stale_after_hours, @default_stale_after_hours) * 3600

    seconds = age_in_seconds(age_reference, now)

    cond do
      seconds < stuck_after -> :leave
      seconds >= stale_after -> :close
      true -> :rescue
    end
  end

  @doc """
  The reason written onto a receipt that is closed rather than sent.

  Spelled out on the record because six months from now the only thing left
  is this string, and "failed" alone would send someone back to the logs.
  """
  @spec close_reason(DateTime.t() | NaiveDateTime.t(), keyword()) :: String.t()
  def close_reason(age_reference, opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    hours = div(age_in_seconds(age_reference, now), 3600)

    "Stranded in :scheduled for #{hours}h with no live job — too old to send, " <>
      "closed by the stranded-receipt sweep rather than delivered late."
  end

  @doc "Default grace period in minutes, before a `:scheduled` receipt counts as stranded."
  @spec default_stuck_after_minutes() :: pos_integer()
  def default_stuck_after_minutes, do: @default_stuck_after_minutes

  @doc "Default staleness ceiling in hours, past which a receipt is closed instead of sent."
  @spec default_stale_after_hours() :: pos_integer()
  def default_stale_after_hours, do: @default_stale_after_hours

  defp age_in_seconds(%DateTime{} = reference, now), do: DateTime.diff(now, reference)

  defp age_in_seconds(%NaiveDateTime{} = reference, now) do
    DateTime.diff(now, DateTime.from_naive!(reference, "Etc/UTC"))
  end
end
