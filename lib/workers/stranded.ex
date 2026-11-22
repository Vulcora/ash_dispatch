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

      config :ash_dispatch,
        # Younger than this is working, not stranded. Default 30.
        stranded_stuck_after_minutes: 30,

        # Older than this is closed rather than delivered late. Default 24.
        stranded_stale_after_hours: 24

  The grace period wins over a ceiling set below it, so a contradictory
  configuration leaves a receipt alone rather than closing one that is still
  in flight.

  ## `:sending`, and why it is a setting (0.9.4)

  `:sending` was the same dead end, one step further along. A node that goes
  down between `mark_sending` and the provider leaves the receipt there, and
  until 0.9.4 nothing looked: the retry sweep queries `:failed`, this sweep
  queried `:scheduled`, and no transition led out. Oban's lifeline covers the
  case where the JOB survives (`AshDispatch.ReceiptStatus.claim/2` reclaims
  it on the next attempt); it does not cover a job that was pruned, cancelled
  or discarded mid-send.

  What makes `:sending` different from `:scheduled` is that we do not know
  whether the provider got the message. `:scheduled` promises a job is coming
  and nothing has been handed over; `:sending` means the handover may already
  have happened. Rescuing it is therefore an at-least-once resend, and the
  recipient may get the same letter twice.

  That is a real choice, so it is a setting rather than a default:

      config :ash_dispatch, stranded_sending: :ignore   # the default

    * `:ignore` — the sweep does not look at `:sending`. Byte-for-byte what
      every release before 0.9.4 did.
    * `:close` — a stranded `:sending` receipt is marked `:failed_permanent`
      with a reason saying the outcome is unknown. **Nothing is sent twice,
      and the silent loss stops being silent.** This is the one to pick if
      you do not want to think about it.
    * `:rescue` — the same three outcomes as `:scheduled`: leave, hand to the
      retry machinery, or close past the staleness ceiling. At-least-once
      delivery, and a possible duplicate, in exchange for not losing a letter
      the provider never saw.

  The grace period applies either way, so a send that is merely in progress
  is never touched.
  """

  @default_stuck_after_minutes 30
  @default_stale_after_hours 24
  @default_sending_mode :ignore

  @typedoc "What should happen to a receipt sitting in `:scheduled`."
  @type action :: :leave | :rescue | :close

  @typedoc "How the sweep treats a receipt sitting in `:sending`."
  @type sending_mode :: :ignore | :close | :rescue

  require Logger

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
    now = Keyword.get(opts, :now) || AshDispatch.Clock.utc_now()
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
    now = Keyword.get(opts, :now) || AshDispatch.Clock.utc_now()
    hours = div(age_in_seconds(age_reference, now), 3600)

    "Stranded in :scheduled for #{hours}h with no live job — too old to send, " <>
      "closed by the stranded-receipt sweep rather than delivered late."
  end

  @doc """
  Decides the fate of one receipt sitting in `:sending`.

  Same grace period as `action/2` — a send in progress is not stranded — and
  then whatever `mode` says. See the moduledoc for why this is a setting.

      iex> AshDispatch.Workers.Stranded.sending_action(DateTime.utc_now(), :close)
      :leave
  """
  @spec sending_action(DateTime.t() | NaiveDateTime.t(), sending_mode(), keyword()) :: action()
  def sending_action(age_reference, mode \\ nil, opts \\ []) do
    case mode || sending_mode() do
      mode when mode in [:close, :rescue] ->
        case action(age_reference, opts) do
          # Not stranded yet, whatever the mode: a live send is not a loss.
          :leave ->
            :leave

          # Past the staleness ceiling closes under both modes; `:close` also
          # closes everything past the grace period, because a resend is the
          # one thing it is there to avoid.
          :close ->
            :close

          :rescue ->
            cond do
              mode == :close -> :close
              # `:rescue` hands a receipt to the retry machinery — which only
              # looks at receipts with retries LEFT. A receipt whose budget is
              # spent would sit in `:failed` and be swept back here next pass,
              # for ever, with the books saying "will be retried". Closed
              # instead, which is what it is.
              retries_spent?(opts) -> :close
              true -> :rescue
            end
        end

      :ignore ->
        :leave

      other ->
        # Not treated as anything. `:ignore` would be the quiet reading, and a
        # typo in a setting about losing letters should not be read quietly —
        # but it is once per SWEEP rather than per receipt, so a hundred
        # stranded receipts are one line.
        warn_once(other)
        :leave
    end
  end

  defp retries_spent?(opts) do
    case {Keyword.get(opts, :retry_count), Keyword.get(opts, :max_retries)} do
      {count, max} when is_integer(count) and is_integer(max) -> count >= max
      _ -> false
    end
  end

  @doc false
  # The invalid-mode warning, once per sweep. The sweep calls `forget_warning/0`
  # before it starts, so a host that fixes the setting sees the line stop and a
  # host that does not sees one line a pass.
  @spec forget_warning() :: :ok
  def forget_warning do
    Process.delete({__MODULE__, :warned})
    :ok
  end

  defp warn_once(value) do
    unless Process.get({__MODULE__, :warned}) do
      Process.put({__MODULE__, :warned}, true)

      Logger.warning(
        "AshDispatch: config :ash_dispatch, stranded_sending: #{inspect(value)} is not " <>
          ":ignore, :close or :rescue. Nothing in :sending is swept. See " <>
          "AshDispatch.Workers.Stranded."
      )
    end

    :ok
  end

  @doc """
  The reason written onto a receipt closed out of `:sending`.

  Says what the earlier reason could not: that the provider may or may not
  have had it. A receipt that reads "failed" when the letter was in fact
  delivered is its own kind of lie, and this is the honest version.
  """
  @spec sending_close_reason(DateTime.t() | NaiveDateTime.t(), keyword()) :: String.t()
  def sending_close_reason(age_reference, opts \\ []) do
    now = Keyword.get(opts, :now) || AshDispatch.Clock.utc_now()
    hours = div(age_in_seconds(age_reference, now), 3600)

    "Stranded in :sending for #{hours}h with no live job. Whether the provider " <>
      "accepted this message is unknown, so it was closed rather than sent again " <>
      "(config :ash_dispatch, stranded_sending: :rescue to resend instead)."
  end

  @doc """
  The reason written onto a receipt handed back to the retry machinery out of
  `:sending`, under `stranded_sending: :rescue`.
  """
  @spec sending_rescue_reason() :: String.t()
  def sending_rescue_reason do
    "Stranded in :sending with no live job — returned for retry. This may be a " <>
      "second send of a message the provider already accepted (config " <>
      ":ash_dispatch, stranded_sending: :rescue)."
  end

  @doc """
  The configured `:sending` mode, `:ignore` unless a host says otherwise.
  """
  @spec sending_mode() :: sending_mode() | term()
  def sending_mode do
    Application.get_env(:ash_dispatch, :stranded_sending, @default_sending_mode)
  end

  @doc "The default `:sending` mode: `:ignore`, which is what every release before 0.9.4 did."
  @spec default_sending_mode() :: sending_mode()
  def default_sending_mode, do: @default_sending_mode

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
