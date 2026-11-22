defmodule AshDispatch.Transport.Queue do
  @moduledoc """
  Which Oban queue a channel's send job goes into.

  `SendEmail`, `SendSMS` and `SendWebhook` were bound to `:emails`, `:sms` and
  `:webhooks` at compile time. An installation that sends two thousand letters
  in a campaign starved every booking confirmation behind them for minutes,
  and the only way out was a second send path of its own — one host wrote
  three hundred lines for exactly that.

  Two levels now, and today's names are both defaults:

  1. **Per transport**, in config — `email_queue`, `sms_queue`,
     `webhook_queue`. Every job of that transport, retries and digests
     included, because the workers read it in `__opts__`.
  2. **Per channel**, as `queue:` in the DSL. Only that channel's jobs, so the
     campaign's channel can name `:bulk_emails` while every other email
     channel stays where it was.

  A channel that names no queue goes exactly where it went before.

  ## A queue nothing runs

  Oban does not complain about a job enqueued into a queue it is not running:
  the row is inserted and nothing ever picks it up. That is a silent lost
  letter, which is the failure mode this library spends most of its care on,
  so `opts/1` says so in the log — once per queue per boot, because it is a
  configuration mistake and not an event.
  """

  alias AshDispatch.Config

  require Logger

  @doc """
  Oban job options for `channel`, to merge over a worker's `__opts__`.

  `[]` when the channel names no queue of its own, which leaves the
  transport's configured queue in place.
  """
  @spec opts(map() | nil) :: keyword()
  def opts(channel) do
    case channel && Map.get(channel, :queue) do
      queue when is_atom(queue) and not is_nil(queue) ->
        warn_unless_running(queue)
        [queue: queue]

      nil ->
        []

      other ->
        # Refused rather than passed through. Oban's queue names are atoms, a
        # string names no queue it is running, and the job would be inserted
        # into a queue nothing picks up — a silently lost letter, which is the
        # failure this module exists to catch. `String.to_atom/1` is not the
        # answer either: a channel's queue can come from a manual dispatch's
        # override, which is to say from outside.
        Logger.warning(
          "[AshDispatch] ignoring queue #{inspect(other)}: a queue name is an atom, " <>
            "and this channel's jobs go to the transport's queue instead"
        )

        []
    end
  end

  @doc """
  The queue `transport`'s jobs run in, channel overrides aside.

  `AshDispatch.Config.transport_queue/1` is where the names live; this is the
  same answer, for a host that wants to print it.
  """
  @spec for_transport(atom()) :: atom() | nil
  def for_transport(transport), do: Config.transport_queue(transport)

  @doc false
  # Test hook: makes the missing-queue warning fire again.
  @spec forget_warning(term()) :: :ok
  def forget_warning(queue) do
    :persistent_term.erase({__MODULE__, :missing_queue, to_string(queue)})
    :ok
  end

  defp warn_unless_running(queue) do
    case running_queues() do
      :unknown ->
        :ok

      queues ->
        key = {__MODULE__, :missing_queue, to_string(queue)}

        if to_string(queue) not in queues and not :persistent_term.get(key, false) do
          # Once per queue per boot, the way `Channel.warn_window_deprecated/0`
          # does it: a configuration mistake is not an event, and this runs on
          # every dispatch of the channel that has it.
          :persistent_term.put(key, true)

          Logger.warning(
            "[AshDispatch] enqueueing into queue #{inspect(queue)}, which this Oban " <>
              "instance is not running (#{Enum.join(queues, ", ")}). Jobs there are " <>
              "inserted and never picked up."
          )
        end
    end
  end

  # `:unknown` rather than a guess: Oban may not be started (a test, a release
  # step), may be configured elsewhere, or may be running with a dynamic queue
  # list. A warning we are not sure about is worse than none.
  defp running_queues do
    case Oban.config() do
      %{queues: queues} when is_list(queues) and queues != [] ->
        Enum.map(queues, fn
          {name, _opts} -> to_string(name)
          name -> to_string(name)
        end)

      _ ->
        :unknown
    end
  rescue
    _ -> :unknown
  catch
    _, _ -> :unknown
  end
end
