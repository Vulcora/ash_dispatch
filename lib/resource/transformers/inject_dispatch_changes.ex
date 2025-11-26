defmodule AshDispatch.Resource.Transformers.InjectDispatchChanges do
  @moduledoc """
  Transformer that automatically injects DispatchEvent changes into actions.

  For each event defined in the `dispatch` section, this transformer finds the
  corresponding action(s) specified by `trigger_on` and adds a `DispatchEvent`
  change to dispatch the event after the action completes.

  ## Example

  Given this resource:

      dispatch do
        event :created, trigger_on: :create_from_cart do
          channels do
            channel :email, :user
          end
        end
      end

  The transformer will inject:

      create :create_from_cart do
        # ... existing action logic ...

        # AUTO-INJECTED:
        change {AshDispatch.Changes.DispatchEvent,
                event_id: "product_order.created",
                load: [],
                event_config: %{...}}
      end

  ## Multiple Actions

  If `trigger_on` is a list, the change is injected into all specified actions:

      event :status_changed, trigger_on: [:process, :complete, :cancel] do
        # ...
      end

  ## Skipping Injection

  If the event has a `module` specified, the transformer still injects the change
  but passes the module reference for custom handling.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  # Run after ValidateEvents (which runs after SetPrimaryActions)
  @impl true
  def after?(AshDispatch.Resource.Transformers.ValidateEvents), do: true

  @impl true
  def after?(_), do: false

  @impl true
  def transform(dsl_state) do
    # Get all events from the dispatch section
    events = Transformer.get_entities(dsl_state, [:dispatch])

    # Get the resource module for generating event ID
    resource = Transformer.get_persisted(dsl_state, :module)

    # Build a map of event_id -> channels for persistence
    dispatch_channels =
      events
      |> Enum.map(fn event ->
        event_id = event.event_id || generate_event_id(resource, event.name)
        channels = build_channels(event.channels)
        {event_id, channels}
      end)
      |> Enum.into(%{})

    # Persist channels on the resource for runtime access
    dsl_state = Transformer.persist(dsl_state, :dispatch_channels, dispatch_channels)

    # For each event, inject the dispatch change into the triggered action(s)
    dsl_state =
      Enum.reduce(events, dsl_state, fn event, acc_dsl_state ->
        inject_event_dispatch(acc_dsl_state, event)
      end)

    {:ok, dsl_state}
  end

  # Build Channel structs from DSL config
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
        webhook_url: get_val.(:webhook_url, nil),
        opts: get_val.(:opts, %{})
      }
    end)
  end

  # Private helpers

  defp inject_event_dispatch(dsl_state, event) do
    # Normalize trigger_on to always be a list
    action_names =
      case event.trigger_on do
        name when is_atom(name) -> [name]
        names when is_list(names) -> names
      end

    # Inject dispatch change into each action
    Enum.reduce(action_names, dsl_state, fn action_name, acc_dsl_state ->
      inject_into_action(acc_dsl_state, action_name, event)
    end)
  end

  defp inject_into_action(dsl_state, action_name, event) do
    # Get the resource module for generating event ID
    resource = Transformer.get_persisted(dsl_state, :module)

    # Generate event ID if not explicitly set
    event_id =
      event.event_id ||
        generate_event_id(resource, event.name)

    # Extract domain and resource names for template path resolution
    domain_name = extract_domain_name(resource)
    resource_name = extract_resource_name(resource)

    # Build the DispatchEvent change configuration
    # Only include recipient_filter if it's actually configured (not empty)
    recipient_filter =
      case event.recipient_filter do
        map when map == %{} -> nil
        list when list == [] -> nil
        filter -> filter
      end

    # Auto-derive load requirements from audience
    derived_load = derive_load_from_audience(event, dsl_state)

    change_opts = [
      event_id: event_id,
      load: derived_load,
      event_config: %{
        channels: event.channels,
        content: event.content,
        metadata: event.metadata,
        module: event.module,
        data_key: event.data_key,
        recipient_filter: recipient_filter,
        # For template path resolution
        domain: domain_name,
        # For template path resolution
        resource_name: resource_name,
        # For source resource linking (used by extract_source_info in dispatcher)
        resource_module: resource
      }
    ]

    # Find the action and add the change
    # This uses Ash's transformer API to modify the action
    case find_action(dsl_state, action_name) do
      nil ->
        # Action not found - this will be caught by ValidateEvents transformer
        dsl_state

      action ->
        # Add the DispatchEvent change to the action
        add_change_to_action(dsl_state, action, change_opts)
    end
  end

  defp generate_event_id(resource, event_name) when is_atom(resource) do
    # Use resource.event format to avoid collisions when multiple resources
    # in the same domain use common event names (e.g., :created, :updated)
    # E.g., Magasin.Requests.ResellerRequest + :created -> "reseller_request.created"
    resource_name =
      resource
      |> Module.split()
      |> List.last()
      |> Macro.underscore()

    "#{resource_name}.#{event_name}"
  end

  defp generate_event_id(_resource, event_name), do: "unknown.#{event_name}"

  defp extract_domain_name(resource) when is_atom(resource) do
    # Extract domain name from module path for template path resolution
    # E.g., Magasin.Requests.ResellerRequest -> "requests"
    # Takes the second-to-last module segment as the domain
    module_parts = Module.split(resource)

    case length(module_parts) do
      n when n >= 2 ->
        # Get second-to-last segment (domain name)
        module_parts
        |> Enum.at(-2)
        |> Macro.underscore()

      _ ->
        nil
    end
  end

  defp extract_domain_name(_), do: nil

  defp extract_resource_name(resource) when is_atom(resource) do
    # Extract resource name from module path for template path resolution
    # E.g., Magasin.Requests.ResellerRequest -> "reseller_request"
    # Takes the last module segment as the resource name
    resource
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  defp extract_resource_name(_), do: nil

  defp find_action(dsl_state, action_name) do
    dsl_state
    |> Transformer.get_entities([:actions])
    |> Enum.find(fn action -> action.name == action_name end)
  end

  defp add_change_to_action(dsl_state, action, change_opts) do
    # Build the change struct (Ash expects %Ash.Resource.Change{}, not a plain tuple)
    change = %Ash.Resource.Change{
      change: {AshDispatch.Changes.DispatchEvent, change_opts},
      on: nil,
      only_when_valid?: false,
      description: "Auto-injected event dispatcher",
      where: [],
      always_atomic?: false,
      __spark_metadata__: nil
    }

    # Add the change to the action's changes list
    existing_changes = Map.get(action, :changes, [])
    updated_action = Map.put(action, :changes, existing_changes ++ [change])

    # Replace this specific action in the DSL state
    Transformer.replace_entity(dsl_state, [:actions], updated_action, fn existing_action ->
      existing_action.name == action.name
    end)
  end

  # Auto-derive load requirements based on audience
  # Uses the audiences config + resource DSL (prefix/overrides) to resolve what relationships to load
  # e.g., :user loads :user, :admin (configured as [:user, admin: true]) loads nothing
  # For child resources with prefix: :user becomes [:order, :user] -> [order: :user]
  defp derive_load_from_audience(event, dsl_state) do
    explicit_load = event.load || []

    # Get configured audiences from AshDispatch config
    audiences_config = get_audiences_config()

    # Get resource-level audience configuration from DSL
    audience_prefix = get_audience_prefix(dsl_state)
    audience_overrides = get_audience_overrides(dsl_state)

    # Extract all atom audiences from channels
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

    # Get resource relationships from DSL state (compile-time)
    relationships = get_relationship_names_from_dsl(dsl_state)

    # Resolve each audience to its load path and add to load list
    Enum.reduce(atom_audiences, explicit_load, fn audience_name, acc ->
      # Build the full path for this audience
      path =
        resolve_audience_path(
          audience_name,
          audiences_config,
          audience_prefix,
          audience_overrides
        )

      # Convert path to nested load structure
      load_spec = path_to_load(path, relationships)

      if load_spec do
        already_loaded = load_already_present?(acc, load_spec)
        if already_loaded, do: acc, else: [load_spec | acc]
      else
        acc
      end
    end)
  end

  # Get audience_prefix from resource DSL (singleton entity)
  defp get_audience_prefix(dsl_state) do
    case Transformer.get_entities(dsl_state, [:dispatch]) do
      entities ->
        Enum.find_value(entities, fn
          %AshDispatch.Resource.Dsl.AudiencePrefix{prefix: prefix} -> prefix
          _ -> nil
        end)
    end
  end

  # Get audience overrides from resource DSL
  defp get_audience_overrides(dsl_state) do
    Transformer.get_entities(dsl_state, [:dispatch])
    |> Enum.filter(fn
      %AshDispatch.Resource.Dsl.AudienceOverride{} -> true
      _ -> false
    end)
    |> Enum.map(fn override -> {override.name, override.path} end)
    |> Enum.into(%{})
  end

  # Build the full relationship path for an audience
  # Priority: explicit override > prefix + global config > global config alone
  defp resolve_audience_path(audience_name, audiences_config, prefix, overrides) do
    # Check for explicit override first
    case Map.get(overrides, audience_name) do
      path when is_list(path) and path != [] ->
        path

      _ ->
        # Check if this is a relationship audience from config
        case resolve_audience_relationship(audience_name, audiences_config) do
          nil ->
            # Broadcast audience - no path to load
            []

          relationship_name ->
            # Relationship audience - apply prefix if present
            if prefix do
              [prefix, relationship_name]
            else
              [relationship_name]
            end
        end
    end
  end

  # Convert a relationship path to nested load structure
  # [:user] -> :user
  # [:order, :user] -> [order: :user]
  # [:order, :user, :preferences] -> [order: [user: :preferences]]
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

  # Build nested keyword structure from path
  # [:user] -> :user
  # [:user, :preferences] -> [user: :preferences]
  defp build_nested_load([single]), do: single
  defp build_nested_load([first | rest]), do: [{first, build_nested_load(rest)}]

  # Check if a load spec is already present in the load list
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

  # Resolve audience to its relationship from config
  # Only relationship audiences need loading, broadcast audiences don't
  # :user (bare atom in config) -> relationship -> load :user
  # :admin (keyword in config as [:user, admin: true]) -> broadcast -> load nothing
  defp resolve_audience_relationship(audience_name, audiences_config) do
    case Keyword.get(audiences_config, audience_name) do
      # Bare atom means it's a relationship audience
      # e.g., :user in config becomes {user: :user}
      ^audience_name ->
        audience_name

      # Keyword entry like `admin: [:user, admin: true]` is a BROADCAST audience
      # It queries User resource with filter, NOT a relationship to load
      [_resource | _filter] ->
        nil

      # Not in config - assume it IS a relationship audience (backward compatibility)
      # This allows bare atom audiences to work without explicit config
      nil ->
        audience_name

      _ ->
        nil
    end
  end

  # Get audiences config
  defp get_audiences_config do
    audiences = Application.get_env(:ash_dispatch, :audiences, [])

    # Convert list format to keyword list for lookup
    # [:user, admin: [...]] -> [user: :user, admin: [...]]
    Enum.flat_map(audiences, fn
      atom when is_atom(atom) -> [{atom, atom}]
      {key, value} -> [{key, value}]
    end)
  end

  # Get relationship names from DSL state at compile time
  # This is more reliable than Ash.Resource.Info.relationships() during compilation
  defp get_relationship_names_from_dsl(dsl_state) do
    dsl_state
    |> Transformer.get_entities([:relationships])
    |> Enum.map(& &1.name)
  end
end
