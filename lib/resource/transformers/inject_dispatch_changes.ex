defmodule AshDispatch.Resource.Transformers.InjectDispatchChanges do
  @moduledoc """
  Transformer that registers `AshDispatch.Notifier` and persists
  per-action dispatch-event config for resources using the `dispatch`
  DSL block.

  ## Pattern (post-tx-semantics retrofit)

  Mirrors `Ash.Notifier.PubSub.Info`'s shape: a single notifier
  (`AshDispatch.Notifier`) handles ALL resources' dispatch events; the
  per-action config is persisted into dsl_state and read at runtime
  by `AshDispatch.Notifier.Info.dispatch_events_for/2`.

  Pre-retrofit, this transformer injected
  `change AshDispatch.Changes.DispatchEvent` per action — that change
  fired via `Ash.Changeset.after_action/2` synchronously inside the
  action's transaction BEFORE commit/rollback, allowing phantom
  dispatches on rollback. Post-retrofit, work happens in
  `Ash.Notifier`'s post-commit drain (or is dropped on error). See
  `AshDispatch.Notifier` moduledoc for the architectural justification.

  ## Persisted state

  - `:dispatch_channels` — `%{event_id => [%Channel{}, ...]}` (kept)
  - `:ash_dispatch_dispatch_events` — NEW;
    `%{action_name => [event_config_map, ...]}` for the notifier to
    consume per-action.
  - `:simple_notifiers` — adds `AshDispatch.Notifier` (mirrors
    `InjectEntityNotifier`'s pattern).
  """

  use Spark.Dsl.Transformer

  alias AshDispatch.Config
  alias AshDispatch.Naming
  alias Spark.Dsl.Transformer

  @notifier AshDispatch.Notifier

  # Run after ValidateEvents (which runs after SetPrimaryActions)
  @impl true
  def after?(AshDispatch.Resource.Transformers.ValidateEvents), do: true

  @impl true
  def after?(_), do: false

  @impl true
  def transform(dsl_state) do
    events = Transformer.get_entities(dsl_state, [:dispatch])
    resource = Transformer.get_persisted(dsl_state, :module)
    domain_name = Naming.domain_name(resource)

    # First pass: auto-derive event_id, module, domain, data_key on
    # each %Event{} so Info.events() returns hydrated events.
    dsl_state =
      Enum.reduce(events, dsl_state, fn event, acc_dsl_state ->
        case event do
          %AshDispatch.Resource.Dsl.Event{name: name} = evt ->
            updated_event =
              if is_nil(evt.event_id) do
                %{evt | event_id: Naming.event_id(resource, name)}
              else
                evt
              end

            updated_event =
              if is_nil(updated_event.module) do
                resolved_module = resolve_event_module(updated_event, resource, domain_name)
                %{updated_event | module: resolved_module}
              else
                updated_event
              end

            updated_event =
              if is_nil(updated_event.domain) do
                derived_domain = domain_name && String.to_atom(domain_name)
                %{updated_event | domain: derived_domain}
              else
                updated_event
              end

            updated_event =
              if is_nil(updated_event.data_key) do
                %{updated_event | data_key: Naming.data_key(resource)}
              else
                updated_event
              end

            if updated_event != evt do
              Transformer.replace_entity(acc_dsl_state, [:dispatch], updated_event, fn existing ->
                match?(%AshDispatch.Resource.Dsl.Event{name: ^name}, existing)
              end)
            else
              acc_dsl_state
            end

          _ ->
            acc_dsl_state
        end
      end)

    events = Transformer.get_entities(dsl_state, [:dispatch])

    # Build dispatch_channels persistence map (kept).
    dispatch_channels =
      events
      |> Enum.filter(&match?(%AshDispatch.Resource.Dsl.Event{}, &1))
      |> Enum.map(fn event ->
        event_id = event.event_id || Naming.event_id(resource, event.name)
        channels = build_channels(event.channels)
        {event_id, channels}
      end)
      |> Enum.into(%{})

    dsl_state = Transformer.persist(dsl_state, :dispatch_channels, dispatch_channels)

    # Build per-action event-config map: %{action_name => [event_config, ...]}.
    # An event with `trigger_on: [:create, :update]` produces an entry
    # in BOTH action lists. Manual events (`trigger_on: :manual`) are
    # excluded — they're dispatched programmatically via
    # Dispatcher.dispatch/2,3, not through the action lifecycle.
    dispatch_events =
      events
      |> Enum.filter(&match?(%AshDispatch.Resource.Dsl.Event{}, &1))
      |> Enum.reject(&(&1.trigger_on == :manual))
      |> Enum.flat_map(fn event ->
        action_names =
          case event.trigger_on do
            name when is_atom(name) -> [name]
            names when is_list(names) -> names
          end

        event_config = build_event_config(event, dsl_state, resource, domain_name)
        Enum.map(action_names, fn action_name -> {action_name, event_config} end)
      end)
      |> Enum.group_by(
        fn {action_name, _config} -> action_name end,
        fn {_action_name, config} -> config end
      )

    dsl_state = Transformer.persist(dsl_state, :ash_dispatch_dispatch_events, dispatch_events)

    # Register the AshDispatch.Notifier on this resource so Ash invokes
    # its `notify/1` after every action. The notifier reads the
    # per-action config persisted above. Mirror of
    # `InjectEntityNotifier`'s pattern at line 38 of that transformer.
    dsl_state = ensure_notifier_registered(dsl_state)

    {:ok, dsl_state}
  end

  # ── Build per-action event_config (persisted, not injected) ──────

  # Same shape as the prior `change_opts` keyword list, but as a map
  # for dsl_state persistence ergonomics (Spark.Dsl.Transformer.persist/3
  # round-trips both shapes; map is more natural for read-side pattern
  # matching in `AshDispatch.Notifier.DispatchHandler`).
  defp build_event_config(event, dsl_state, resource, domain_name) do
    event_id = event.event_id || Naming.event_id(resource, event.name)
    resource_name = Naming.resource_name(resource)
    event_module = resolve_event_module(event, resource, domain_name)

    recipient_filter =
      case event.recipient_filter do
        map when map == %{} -> nil
        list when list == [] -> nil
        filter -> filter
      end

    derived_load = derive_load_from_audience(event, dsl_state)
    resource_locales = get_resource_locales(dsl_state)

    %{
      event_id: event_id,
      load: derived_load,
      event_config: %{
        channels: event.channels,
        content: event.content,
        metadata: event.metadata,
        priority: event.priority || :standard,
        module: event_module,
        data_key: event.data_key,
        include_actor_as: event.include_actor_as,
        recipient_filter: recipient_filter,
        domain: domain_name,
        resource_name: resource_name,
        resource_module: resource,
        locale_from: event.locale_from || resource_locales[:locale_from],
        locales: event.locales || resource_locales[:locales] || [],
        default_locale: resource_locales[:default_locale]
      }
    }
  end

  defp ensure_notifier_registered(dsl_state) do
    existing = Transformer.get_persisted(dsl_state, :simple_notifiers) || []

    if @notifier in existing do
      dsl_state
    else
      Transformer.persist(dsl_state, :simple_notifiers, [@notifier | existing])
    end
  end

  # ── Channel construction (preserved verbatim) ───────────────────

  defp build_channels(channel_configs) do
    Enum.map(channel_configs, fn channel_config ->
      get_val = fn key, default ->
        cond do
          is_list(channel_config) -> Keyword.get(channel_config, key, default)
          is_map(channel_config) -> Map.get(channel_config, key, default)
          true -> default
        end
      end

      %AshDispatch.Channel{
        transport: get_val.(:transport, nil),
        audience: get_val.(:audience, nil),
        time: get_val.(:time, {:in, 0}),
        policy: get_val.(:policy, :always),
        variant: get_val.(:variant, nil),
        locale: get_val.(:locale, nil),
        locale_from: get_val.(:locale_from, nil),
        locales: get_val.(:locales, []),
        webhook_url: get_val.(:webhook_url, nil),
        deduplicate_group: get_val.(:deduplicate_group, nil),
        optional: get_val.(:optional, false),
        opts: get_val.(:opts, %{})
      }
    end)
  end

  # ── Audience-derived load resolution (preserved verbatim) ────────

  defp derive_load_from_audience(event, dsl_state) do
    explicit_load = event.load || []
    audiences_config = get_audiences_config()
    audience_prefix = get_audience_prefix(dsl_state)
    audience_overrides = get_audience_overrides(dsl_state)

    atom_audiences =
      event.channels
      |> Enum.map(fn channel ->
        cond do
          is_map(channel) -> Map.get(channel, :audience)
          is_list(channel) -> Keyword.get(channel, :audience)
          true -> nil
        end
      end)
      |> Enum.filter(&is_atom/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    relationships = get_relationship_names_from_dsl(dsl_state)

    Enum.reduce(atom_audiences, explicit_load, fn audience_name, acc ->
      path =
        resolve_audience_path(
          audience_name,
          audiences_config,
          audience_prefix,
          audience_overrides
        )

      load_spec = path_to_load(path, relationships)

      if load_spec do
        already_loaded = load_already_present?(acc, load_spec)
        if already_loaded, do: acc, else: [load_spec | acc]
      else
        acc
      end
    end)
  end

  defp get_audience_prefix(dsl_state) do
    case Transformer.get_entities(dsl_state, [:dispatch]) do
      entities ->
        Enum.find_value(entities, fn
          %AshDispatch.Resource.Dsl.AudiencePrefix{prefix: prefix} -> prefix
          _ -> nil
        end)
    end
  end

  defp get_audience_overrides(dsl_state) do
    Transformer.get_entities(dsl_state, [:dispatch])
    |> Enum.filter(fn
      %AshDispatch.Resource.Dsl.AudienceOverride{} -> true
      _ -> false
    end)
    |> Enum.map(fn override -> {override.name, override.path} end)
    |> Enum.into(%{})
  end

  defp get_resource_locales(dsl_state) do
    case Transformer.get_entities(dsl_state, [:dispatch]) do
      entities ->
        Enum.find_value(entities, %{}, fn
          %AshDispatch.Resource.Dsl.Locales{} = locales ->
            %{
              locales: locales.locales,
              default_locale: locales.default_locale,
              locale_from: locales.locale_from
            }

          _ ->
            nil
        end)
    end
  end

  defp resolve_audience_path(audience_name, audiences_config, prefix, overrides) do
    case Map.get(overrides, audience_name) do
      path when is_list(path) and path != [] ->
        path

      _ ->
        case resolve_audience_relationship(audience_name, audiences_config) do
          nil ->
            []

          relationship_name ->
            if prefix do
              [prefix, relationship_name]
            else
              [relationship_name]
            end
        end
    end
  end

  defp path_to_load([], _relationships), do: nil

  defp path_to_load([single], relationships) do
    if single in relationships, do: single, else: nil
  end

  defp path_to_load([first | rest], relationships) do
    if first in relationships do
      nested = build_nested_load(rest)
      [{first, nested}]
    else
      nil
    end
  end

  defp build_nested_load([single]), do: single
  defp build_nested_load([first | rest]), do: [{first, build_nested_load(rest)}]

  defp load_already_present?(load_list, spec) when is_atom(spec) do
    Enum.any?(load_list, fn
      ^spec -> true
      {^spec, _} -> true
      [{^spec, _}] -> true
      _ -> false
    end)
  end

  defp load_already_present?(load_list, [{key, _nested}]) do
    Enum.any?(load_list, fn
      ^key -> true
      {^key, _} -> true
      [{^key, _}] -> true
      _ -> false
    end)
  end

  defp load_already_present?(_load_list, _spec), do: false

  defp resolve_audience_relationship(audience_name, audiences_config) do
    case Keyword.get(audiences_config, audience_name) do
      ^audience_name ->
        audience_name

      [_resource | _filter] ->
        nil

      nil ->
        audience_name

      _ ->
        nil
    end
  end

  defp get_audiences_config do
    audiences = Config.audiences()

    Enum.flat_map(audiences, fn
      atom when is_atom(atom) -> [{atom, atom}]
      {key, value} -> [{key, value}]
    end)
  end

  defp get_relationship_names_from_dsl(dsl_state) do
    dsl_state
    |> Transformer.get_entities([:relationships])
    |> Enum.map(& &1.name)
  end

  defp resolve_event_module(event, resource, domain_name) do
    case event.module do
      module when not is_nil(module) ->
        module

      nil ->
        derived_module = Naming.event_module(resource, domain_name, event.name)

        if Code.ensure_loaded?(derived_module) do
          derived_module
        else
          nil
        end
    end
  end
end
