defmodule AshDispatch.Notifier.Info do
  @moduledoc """
  Spark Info module — reads per-action AshDispatch config persisted by
  the resource transformers.

  Mirrors `Ash.Notifier.PubSub.Info`'s pattern: a thin Info module that
  the notifier consults at runtime to find per-action config. The
  config is persisted into dsl_state by
  `AshDispatch.Resource.Transformers.InjectDispatchChanges` (events)
  and `AshDispatch.Resource.Transformers.InjectCounterBroadcasts`
  (counters), then read back via `Spark.Dsl.Extension.get_persisted/3`.

  ## Persisted keys

  - `:ash_dispatch_dispatch_events` — `%{action_name => [event_config, ...]}`
  - `:ash_dispatch_counter_broadcasts` — `%{action_name => [counter_config, ...]}`

  Both keys default to `%{}` when absent (resource without dispatch
  events / counters), and per-action lookups default to `[]`.
  """

  @typedoc "Per-action event-config list — one entry per `event ... do ... end` block targeting the action."
  @type event_config :: %{
          required(:event_id) => String.t(),
          required(:load) => term(),
          required(:event_config) => map()
        }

  @typedoc "Per-action counter-config list — one entry per `counter ... do ... end` block targeting the action."
  @type counter_config :: %{
          required(:counter_name) => atom(),
          required(:resource) => module(),
          required(:query_filter) => term(),
          required(:audience) => atom(),
          required(:invalidates) => list(),
          optional(any()) => any()
        }

  @doc """
  All dispatch events triggered by `action_name` on `resource`.
  Returns `[]` when none are registered.
  """
  @spec dispatch_events_for(module(), atom()) :: [event_config()]
  def dispatch_events_for(resource, action_name) when is_atom(resource) and is_atom(action_name) do
    resource
    |> Spark.Dsl.Extension.get_persisted(:ash_dispatch_dispatch_events, %{})
    |> Map.get(action_name, [])
  end

  @doc """
  All counter broadcasts triggered by `action_name` on `resource`.
  Returns `[]` when none are registered.
  """
  @spec counter_broadcasts_for(module(), atom()) :: [counter_config()]
  def counter_broadcasts_for(resource, action_name)
      when is_atom(resource) and is_atom(action_name) do
    resource
    |> Spark.Dsl.Extension.get_persisted(:ash_dispatch_counter_broadcasts, %{})
    |> Map.get(action_name, [])
  end

  @doc """
  Full dispatch-events map for `resource` keyed by action name. Useful
  for introspection / admin tooling.
  """
  @spec all_dispatch_events(module()) :: %{atom() => [event_config()]}
  def all_dispatch_events(resource) when is_atom(resource) do
    Spark.Dsl.Extension.get_persisted(resource, :ash_dispatch_dispatch_events, %{})
  end

  @doc """
  Full counter-broadcasts map for `resource` keyed by action name.
  """
  @spec all_counter_broadcasts(module()) :: %{atom() => [counter_config()]}
  def all_counter_broadcasts(resource) when is_atom(resource) do
    Spark.Dsl.Extension.get_persisted(resource, :ash_dispatch_counter_broadcasts, %{})
  end
end
