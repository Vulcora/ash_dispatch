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

    # For each event, inject the dispatch change into the triggered action(s)
    dsl_state =
      Enum.reduce(events, dsl_state, fn event, acc_dsl_state ->
        inject_event_dispatch(acc_dsl_state, event)
      end)

    {:ok, dsl_state}
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

    # Build the DispatchEvent change configuration
    change_opts = [
      event_id: event_id,
      load: event.load,
      event_config: %{
        channels: event.channels,
        content: event.content,
        metadata: event.metadata,
        module: event.module
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
    resource_name =
      resource
      |> Module.split()
      |> List.last()
      |> Macro.underscore()

    "#{resource_name}.#{event_name}"
  end

  defp generate_event_id(_resource, event_name), do: "unknown.#{event_name}"

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
end
