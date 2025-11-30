defmodule AshDispatch.Resource.Transformers.ValidateEvents do
  @moduledoc """
  Transformer that validates event configurations.

  Checks:
  - Actions referenced in `trigger_on` actually exist
  - Events have either inline configuration OR a module (not both empty)
  - Channel configurations are valid
  - Event names are unique within the resource
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError

  # Run after Ash's transformers that register and validate actions
  @impl true
  def after?(Ash.Resource.Transformers.SetPrimaryActions), do: true

  @impl true
  def after?(_), do: false

  @impl true
  def transform(dsl_state) do
    events = Transformer.get_entities(dsl_state, [:dispatch])

    with :ok <- validate_unique_names(events, dsl_state),
         :ok <- validate_trigger_actions(events, dsl_state),
         :ok <- validate_event_configs(events, dsl_state) do
      {:ok, dsl_state}
    end
  end

  # Validate event names are unique
  defp validate_unique_names(events, dsl_state) do
    names = Enum.map(events, & &1.name)
    duplicates = names -- Enum.uniq(names)

    case duplicates do
      [] ->
        :ok

      [first | _] ->
        {:error,
         DslError.exception(
           module: Transformer.get_persisted(dsl_state, :module),
           path: [:dispatch],
           message: "Duplicate event name: #{inspect(first)}"
         )}
    end
  end

  # Validate that trigger_on actions exist (skip :manual events)
  defp validate_trigger_actions(events, dsl_state) do
    all_actions = get_all_action_names(dsl_state)

    invalid_events =
      Enum.filter(events, fn event ->
        # Skip validation for manual-only events
        if event.trigger_on == :manual do
          false
        else
          trigger_actions =
            case event.trigger_on do
              name when is_atom(name) -> [name]
              names when is_list(names) -> names
            end

          Enum.any?(trigger_actions, fn action_name ->
            action_name not in all_actions
          end)
        end
      end)

    case invalid_events do
      [] ->
        :ok

      [event | _] ->
        missing =
          case event.trigger_on do
            name when is_atom(name) -> name
            [name | _] -> name
          end

        {:error,
         DslError.exception(
           module: Transformer.get_persisted(dsl_state, :module),
           path: [:dispatch],
           message: """
           Event #{inspect(event.name)} references non-existent action: #{inspect(missing)}

           Available actions: #{inspect(all_actions)}
           """
         )}
    end
  end

  # Validate event has configuration
  defp validate_event_configs(events, dsl_state) do
    invalid_events =
      Enum.filter(events, fn event ->
        # Event must have either channels OR a module
        has_channels = length(event.channels) > 0
        has_module = not is_nil(event.module)

        not (has_channels or has_module)
      end)

    case invalid_events do
      [] ->
        :ok

      [event | _] ->
        {:error,
         DslError.exception(
           module: Transformer.get_persisted(dsl_state, :module),
           path: [:dispatch],
           message: """
           Event #{inspect(event.name)} has no configuration.

           Events must have either:
           - Inline channel/content configuration, OR
           - A callback module via the `module:` option
           """
         )}
    end
  end

  # Helper to get all action names from the resource
  defp get_all_action_names(dsl_state) do
    dsl_state
    |> Transformer.get_entities([:actions])
    |> Enum.map(& &1.name)
  end
end
