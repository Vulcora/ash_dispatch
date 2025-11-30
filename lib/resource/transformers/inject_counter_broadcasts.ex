defmodule AshDispatch.Resource.Transformers.InjectCounterBroadcasts do
  @moduledoc """
  Transformer that automatically injects counter broadcasting into actions.

  For each counter defined in the `counters` section, this transformer finds the
  corresponding action(s) specified by `trigger_on` and adds a counter broadcasting
  change to update counters after the action completes.

  ## Example

  Given this resource:

      counters do
        counter :pending_orders do
          trigger_on [:create, :accept, :cancel]
          counter_names [:pending_orders]
          invalidates ["orders"]
        end
      end

  The transformer will inject:

      create :create do
        # ... existing action logic ...

        # AUTO-INJECTED:
        change {AshDispatch.Changes.BroadcastCounterUpdate,
                counter_names: [:pending_orders],
                invalidates: ["orders"]}
      end

      update :accept do
        # ... existing action logic ...

        # AUTO-INJECTED:
        change {AshDispatch.Changes.BroadcastCounterUpdate,
                counter_names: [:pending_orders],
                invalidates: ["orders"]}
      end

  ## Multiple Actions

  If `trigger_on` is a list, the change is injected into all specified actions.

  ## Counter Broadcast Integration

  The injected change broadcasts counters using the configured `counter_broadcast_fn`
  function.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer
  require Logger

  # Run after InjectDispatchChanges if it exists
  @impl true
  def after?(AshDispatch.Resource.Transformers.InjectDispatchChanges), do: true

  @impl true
  def after?(_), do: false

  @impl true
  def transform(dsl_state) do
    # Get all counters from the counters section
    counters = Transformer.get_entities(dsl_state, [:counters])

    if Enum.empty?(counters) do
      # No counters defined, nothing to do
      {:ok, dsl_state}
    else
      # For each counter, inject the broadcast change into the triggered action(s)
      dsl_state =
        Enum.reduce(counters, dsl_state, fn counter, acc_dsl_state ->
          inject_counter_broadcast(acc_dsl_state, counter)
        end)

      {:ok, dsl_state}
    end
  end

  # Private helpers

  defp inject_counter_broadcast(dsl_state, counter) do
    # Normalize trigger_on to always be a list
    action_names =
      case counter.trigger_on do
        name when is_atom(name) -> [name]
        names when is_list(names) -> names
      end

    # Inject counter broadcast change into each action
    Enum.reduce(action_names, dsl_state, fn action_name, acc_dsl_state ->
      inject_into_action(acc_dsl_state, action_name, counter)
    end)
  end

  defp inject_into_action(dsl_state, action_name, counter) do
    # Get the resource module from DSL state if not specified in counter
    resource = counter.resource || Transformer.get_persisted(dsl_state, :module)

    # Default counter_name to the counter identifier if not explicitly set
    counter_name = counter.counter_name || counter.name

    # Build the change options - declarative config with query details
    change_opts =
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

    # Find the action and add the change
    case find_action(dsl_state, action_name) do
      nil ->
        # Action not found - log warning but don't fail
        # (similar to dispatch events, validation happens elsewhere)
        Logger.warning(
          "[InjectCounterBroadcasts] Counter #{counter.name} references unknown action #{action_name}"
        )

        dsl_state

      action ->
        # Add the BroadcastCounterUpdate change to the action
        add_change_to_action(dsl_state, action, change_opts)
    end
  end

  defp find_action(dsl_state, action_name) do
    dsl_state
    |> Transformer.get_entities([:actions])
    |> Enum.find(fn action -> action.name == action_name end)
  end

  defp add_change_to_action(dsl_state, action, change_opts) do
    # Build the change struct (Ash expects %Ash.Resource.Change{})
    change = %Ash.Resource.Change{
      change: {AshDispatch.Changes.BroadcastCounterUpdate, change_opts},
      on: nil,
      only_when_valid?: false,
      description: "Auto-injected counter broadcaster",
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
