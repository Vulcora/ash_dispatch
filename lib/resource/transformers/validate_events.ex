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
    # Filter to only Event structs — the dispatch section may also contain
    # EntityChanges, ResourceMeta, AudiencePrefix, etc.
    events =
      dsl_state
      |> Transformer.get_entities([:dispatch])
      |> Enum.filter(&match?(%AshDispatch.Resource.Dsl.Event{}, &1))

    with :ok <- validate_unique_names(events, dsl_state),
         :ok <- validate_trigger_actions(events, dsl_state),
         :ok <- validate_event_configs(events, dsl_state),
         :ok <- validate_action_label_requires_url(events, dsl_state),
         :ok <- validate_required_event_metadata(events, dsl_state) do
      {:ok, dsl_state}
    end
  end

  # F4 — for each event, check that every channel's transport has its
  # `required_event_metadata_keys/0` satisfied by the event's `metadata`
  # map. Pre-F4 the `:oban` transport soft-failed on missing
  # `:oban_worker` (runtime warning + receipt :skipped). Operators
  # discovered the gap only by noticing their Oban queue stayed empty.
  # With F4 the gap is impossible to ship — Spark.Error.DslError points
  # at the registration site at compile time.
  # Event DSL `metadata:` arrives as either a map (when set via the DSL's
  # default-empty `metadata: %{}`) or a keyword list (when authored as
  # `metadata: [k: v]` in the registration). Normalize both shapes.
  defp event_metadata_keys(nil), do: []
  defp event_metadata_keys(meta) when is_map(meta), do: Map.keys(meta)
  defp event_metadata_keys(meta) when is_list(meta), do: Keyword.keys(meta)

  # Channels in event entities arrive as keyword lists (`[transport: :x,
  # audience: :y]`) — not `%AshDispatch.Dsl.Channel{}` structs. Read the
  # transport field via Keyword.get for the keyword shape; preserve
  # struct shape for any future change that normalizes to structs.
  defp channel_transport(channel) when is_list(channel), do: Keyword.get(channel, :transport)
  defp channel_transport(%{transport: transport}), do: transport

  defp validate_required_event_metadata(events, dsl_state) do
    bad_events =
      Enum.flat_map(events, fn event ->
        event_meta_keys = event_metadata_keys(event.metadata)

        Enum.flat_map(event.channels, fn channel ->
          transport = channel_transport(channel)

          required = AshDispatch.Transport.Registry.required_event_metadata_keys(transport)
          missing = required -- event_meta_keys

          if missing == [], do: [], else: [{event.name, transport, missing}]
        end)
      end)

    case bad_events do
      [] ->
        :ok

      [{event_name, transport, missing} | _] ->
        {:error,
         DslError.exception(
           module: Transformer.get_persisted(dsl_state, :module),
           path: [:dispatch, event_name],
           message: """
           Event `#{inspect(event_name)}` declares a `transport: #{inspect(transport)}` channel \
           but is missing required metadata key(s): #{inspect(missing)}

           Add the keys to the event's `metadata:` block. Example for `:oban`:

               event #{inspect(event_name)},
                 channels: [[transport: #{inspect(transport)}, audience: :system]],
                 metadata: [
                   oban_worker: MyApp.Workers.X,
                   oban_unique_keys: [:entry_id]
                 ]

           Required by `AshDispatch.Transports.#{transport |> Atom.to_string() |> Macro.camelize()}.required_event_metadata_keys/0`.
           """
         )}
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

  # Validate that events with action_label also have action_url
  defp validate_action_label_requires_url(events, dsl_state) do
    invalid =
      Enum.find(events, fn event ->
        has_in_app =
          Enum.any?(event.channels, fn
            ch when is_map(ch) -> ch[:transport] == :in_app
            ch when is_list(ch) -> Keyword.get(ch, :transport) == :in_app
          end)

        has_label = (event.content || [])[:action_label] not in [nil, ""]
        has_url = (event.content || [])[:action_url] not in [nil, ""]

        has_in_app and has_label and not has_url
      end)

    case invalid do
      nil ->
        :ok

      event ->
        {:error,
         DslError.exception(
           module: Transformer.get_persisted(dsl_state, :module),
           path: [:dispatch],
           message: """
           Event #{inspect(event.name)} has action_label but no action_url.

           In-app notifications with action_label must also set action_url
           so the frontend knows where to navigate when the button is clicked.
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
