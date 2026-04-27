defmodule AshDispatch.Notifier do
  @moduledoc """
  Single notifier that handles ALL DispatchEvent and counter-broadcast
  work for resources using the AshDispatch DSL.

  ## Why this lives here

  AshDispatch's prior approach registered per-action `change` modules
  via `Ash.Changeset.after_action/2`, which fires synchronously inside
  the action's transaction BEFORE commit/rollback. Wrapping a
  dispatch-emitting action in `Ash.transaction/2` therefore allowed
  phantom dispatches and counter increments to broadcast for rows that
  subsequently rolled back.

  Routing through `Ash.Notifier` instead inherits Ash's commit-deferred
  semantics for free: notifications accumulate in
  `Process.put(:ash_notifications, …)` and fire post-commit, or are
  dropped on error (see `deps/ash/lib/ash.ex:3917-3970` in the
  consuming Mosis app for the defer-and-fire-or-drop trace).

  ## Registration

  Resources don't register this notifier directly. The transformers
  `AshDispatch.Resource.Transformers.InjectDispatchChanges` and
  `AshDispatch.Resource.Transformers.InjectCounterBroadcasts` persist
  per-action config into the resource's dsl_state AND append this
  module to `:simple_notifiers` (mirroring the existing
  `InjectEntityNotifier` pattern at line 38 of that transformer).

  ## Per-action config lookup

  Per-action `event_config` and `counter_config` data — formerly
  embedded as `change_opts` in the change tuple — is now persisted via
  `Spark.Dsl.Transformer.persist/3` and read back via
  `AshDispatch.Notifier.Info`. This mirrors `Ash.Notifier.PubSub`'s
  approach: a single notifier with a Spark Info module reading
  per-action config (per `Ash.Notifier.PubSub.Info.publications/1`).

  ## Side-effect orchestration

  The actual dispatch and counter-broadcast logic is preserved from the
  prior `Changes.DispatchEvent` and `Changes.BroadcastCounterUpdate`
  modules — moved to `AshDispatch.Notifier.DispatchHandler` and
  `AshDispatch.Notifier.CounterHandler` and called from `notify/1`.
  Only the registration point changed; all downstream Dispatcher /
  EventResolver / ChannelResolver collaborators stay unchanged.
  """

  use Ash.Notifier

  alias AshDispatch.Notifier.{CounterHandler, DispatchHandler, Info}

  require Logger

  @impl Ash.Notifier
  def notify(%Ash.Notifier.Notification{action: action} = notification)
      when not is_nil(action) do
    action_name = action.name

    # Both lookups return [] when the action has no registered config —
    # cheap O(1) map lookup keyed by action name.
    event_configs = Info.dispatch_events_for(notification.resource, action_name)
    counter_configs = Info.counter_broadcasts_for(notification.resource, action_name)

    Enum.each(event_configs, fn event_config ->
      safe_dispatch(notification, event_config, :dispatch_event)
    end)

    Enum.each(counter_configs, fn counter_config ->
      safe_dispatch(notification, counter_config, :counter_broadcast)
    end)

    :ok
  end

  def notify(_), do: :ok

  # ── Internal — error-isolated handler invocations ───────────────

  defp safe_dispatch(notification, config, kind) do
    case kind do
      :dispatch_event -> DispatchHandler.dispatch(notification, config)
      :counter_broadcast -> CounterHandler.broadcast(notification, config)
    end
  rescue
    error ->
      Logger.error("""
      [AshDispatch.Notifier] #{kind} failed for action=#{inspect(notification.action.name)} \
      resource=#{inspect(notification.resource)}
      Config: #{inspect(config, limit: :infinity)}
      Error: #{inspect(error)}
      Stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}
      """)

      # Don't crash the notification chain — same posture as the prior
      # change modules' rescue in dispatch_event.ex:127-137.
      :ok
  end
end
