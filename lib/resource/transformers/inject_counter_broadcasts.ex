defmodule AshDispatch.Resource.Transformers.InjectCounterBroadcasts do
  @moduledoc """
  Transformer that registers `AshDispatch.Notifier` and persists
  per-action counter-broadcast config for resources using the
  `counters` DSL block.

  ## Pattern (post-tx-semantics retrofit)

  Pre-retrofit, this transformer injected
  `change AshDispatch.Changes.BroadcastCounterUpdate` per action. The
  change fired via `Ash.Changeset.after_action/2` synchronously inside
  the action's transaction BEFORE commit/rollback, allowing phantom
  counter increments to broadcast for rolled-back rows. Post-retrofit,
  counter logic runs from `AshDispatch.Notifier`'s post-commit
  notification path (or is dropped on error). See
  `AshDispatch.Notifier` moduledoc for the architectural rationale.

  ## Persisted state

  - `:ash_dispatch_counter_broadcasts` — NEW;
    `%{action_name => [counter_config_keyword_list, ...]}` for the
    notifier to consume per-action.
  - `:simple_notifiers` — adds `AshDispatch.Notifier` (idempotent if
    `InjectDispatchChanges` already registered it).
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @notifier AshDispatch.Notifier

  # Run after InjectDispatchChanges if it exists
  @impl true
  def after?(AshDispatch.Resource.Transformers.InjectDispatchChanges), do: true

  @impl true
  def after?(_), do: false

  @impl true
  def transform(dsl_state) do
    counters = Transformer.get_entities(dsl_state, [:counters])

    if Enum.empty?(counters) do
      {:ok, dsl_state}
    else
      counter_broadcasts = build_counter_broadcasts(counters, dsl_state)

      dsl_state =
        dsl_state
        |> Transformer.persist(:ash_dispatch_counter_broadcasts, counter_broadcasts)
        |> ensure_notifier_registered()

      {:ok, dsl_state}
    end
  end

  # ── Build per-action counter-config map ─────────────────────────

  # Same shape as the prior `change_opts` keyword list — kept as
  # keyword list (not map) because `AshDispatch.Notifier.CounterHandler`
  # uses Keyword.fetch!/get for fields like :counter_name, :resource,
  # :query_filter, etc. Preserving the keyword shape avoids a translation
  # layer and matches the prior change-injection contract verbatim.
  defp build_counter_broadcasts(counters, dsl_state) do
    counters
    |> Enum.flat_map(fn counter ->
      action_names =
        case counter.trigger_on do
          name when is_atom(name) -> [name]
          names when is_list(names) -> names
        end

      counter_config = build_counter_config(counter, dsl_state)
      Enum.map(action_names, fn action_name -> {action_name, counter_config} end)
    end)
    |> Enum.group_by(
      fn {action_name, _config} -> action_name end,
      fn {_action_name, config} -> config end
    )
  end

  defp build_counter_config(counter, dsl_state) do
    resource = counter.resource || Transformer.get_persisted(dsl_state, :module)
    counter_name = counter.counter_name || counter.name

    [
      counter_name: counter_name,
      resource: resource,
      query_filter: counter.query_filter,
      audience: counter.audience,
      invalidates: counter.invalidates,
      authorize?: counter.authorize?
    ]
    |> maybe_add_user_id_path(counter.user_id_path)
    |> maybe_add_scope(counter.scope)
    |> maybe_add_filter_by_record(counter.filter_by_record)
  end

  defp ensure_notifier_registered(dsl_state) do
    existing = Transformer.get_persisted(dsl_state, :simple_notifiers) || []

    if @notifier in existing do
      dsl_state
    else
      Transformer.persist(dsl_state, :simple_notifiers, [@notifier | existing])
    end
  end

  defp maybe_add_user_id_path(opts, nil), do: opts

  defp maybe_add_user_id_path(opts, user_id_path) when is_list(user_id_path) do
    Keyword.put(opts, :user_id_path, user_id_path)
  end

  defp maybe_add_scope(opts, nil), do: opts

  defp maybe_add_scope(opts, scope) do
    Keyword.put(opts, :scope, scope)
  end

  defp maybe_add_filter_by_record(opts, nil), do: opts

  defp maybe_add_filter_by_record(opts, filter_by_record)
       when is_list(filter_by_record) or is_map(filter_by_record) do
    Keyword.put(opts, :filter_by_record, filter_by_record)
  end
end
