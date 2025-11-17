defmodule AshDispatch.Changes.DispatchEvent do
  @moduledoc """
  Ash.Resource.Change that dispatches an event after an action succeeds.

  This change is automatically injected into actions by the
  `AshDispatch.Resource.Transformers.InjectDispatchChanges` transformer.

  ## How It Works

  1. **After Action Success**: Only runs if the action succeeds
  2. **Loads Relationships**: Preloads any relationships specified in `load` option
  3. **Builds Context**: Creates `AshDispatch.Context` with event data
  4. **Resolves Configuration**: Uses callback module OR inline config
  5. **Creates Receipts**: Creates `DeliveryReceipt` for each channel
  6. **Dispatches**: Sends to appropriate transports (in-app, email, etc.)

  ## Options

  - `event_id` - The event ID (e.g., "product_order.created")
  - `load` - List of relationships to preload
  - `event_config` - Map containing:
    - `module` - Optional callback module
    - `channels` - List of channel configs
    - `content` - Content map
    - `metadata` - Metadata map

  ## Example

  This change is automatically added by the transformer:

      # In resource DSL:
      dispatch do
        event :created, trigger_on: :create, ...
      end

      # Transformer injects:
      change {AshDispatch.Changes.DispatchEvent,
              event_id: "product_order.created",
              load: [:user],
              event_config: %{...}}
  """

  use Ash.Resource.Change

  alias AshDispatch.{Context, Channel, Dispatcher}
  alias Ash.Changeset

  require Logger

  @impl true
  def change(changeset, opts, context) do
    # Store opts in changeset metadata to be used after_action
    changeset
    |> Changeset.after_action(fn changeset, record ->
      dispatch_event(changeset, record, opts, context)
      {:ok, record}
    end)
  end

  # Private functions

  defp dispatch_event(changeset, record, opts, ash_context) do
    event_id = Keyword.fetch!(opts, :event_id)
    load = Keyword.get(opts, :load, [])
    event_config = Keyword.fetch!(opts, :event_config)

    # Load relationships if specified
    record = maybe_load_relationships(record, load, changeset)

    # Build event context
    context = build_context(event_id, record, changeset, ash_context)

    # Get channels (from module or inline config)
    channels = resolve_channels(context, event_config)

    # Dispatch to all channels
    Enum.each(channels, fn channel ->
      dispatch_to_channel(context, channel, event_config)
    end)

    :ok
  rescue
    error ->
      Logger.error("""
      Failed to dispatch event #{opts[:event_id]}
      Error: #{inspect(error)}
      Stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}
      """)

      # Don't fail the action if event dispatch fails
      :ok
  end

  defp maybe_load_relationships(record, [], _changeset), do: record

  defp maybe_load_relationships(record, load, changeset) do
    # Use Ash.load! to load relationships
    domain = changeset.domain || record.__struct__.__domain__()

    case Ash.load(record, load, domain: domain) do
      {:ok, loaded_record} ->
        loaded_record

      {:error, error} ->
        Logger.warning("""
        Failed to load relationships #{inspect(load)} for event dispatch
        Error: #{inspect(error)}
        Continuing with unloaded record...
        """)

        record
    end
  end

  defp build_context(event_id, record, changeset, ash_context) do
    %Context{
      event_id: event_id,
      data: %{record.__struct__.__schema__(:source) => record},
      resource_key: record.__struct__.__schema__(:source),
      user: Map.get(ash_context, :actor),
      source: :resource_action,
      locale: "en",
      base_url: get_base_url(),
      now: DateTime.utc_now(),
      metadata: %{
        action: changeset.action.name,
        action_type: changeset.action.type
      }
    }
  end

  defp get_base_url do
    # Get base URL from app config
    Application.get_env(:ash_dispatch, :base_url, "http://localhost:4000")
  end

  defp resolve_channels(context, %{module: module}) when not is_nil(module) do
    # Use callback module to get channels
    module.channels(context)
  end

  defp resolve_channels(_context, %{channels: channels}) do
    # Convert inline channel configs to Channel structs
    Enum.map(channels, &channel_config_to_struct/1)
  end

  defp channel_config_to_struct(channel) when is_map(channel) do
    %Channel{
      transport: Map.fetch!(channel, :transport),
      audience: Map.fetch!(channel, :audience),
      time: time_from_delay(Map.get(channel, :delay)),
      policy: Map.get(channel, :policy, :always),
      webhook_url: Map.get(channel, :webhook_url),
      opts: Map.get(channel, :opts, %{})
    }
  end

  defp channel_config_to_struct(channel) when is_list(channel) do
    %Channel{
      transport: Keyword.fetch!(channel, :transport),
      audience: Keyword.fetch!(channel, :audience),
      time: time_from_delay(Keyword.get(channel, :delay)),
      policy: Keyword.get(channel, :policy, :always),
      webhook_url: Keyword.get(channel, :webhook_url),
      opts: Keyword.get(channel, :opts, %{})
    }
  end

  defp time_from_delay(nil), do: {:in, 0}
  defp time_from_delay(seconds) when is_integer(seconds), do: {:in, seconds}

  defp dispatch_to_channel(context, channel, event_config) do
    # Delegate to Dispatcher module which handles:
    # - Creating DeliveryReceipt
    # - Dispatching to appropriate transport
    # - Updating receipt status
    Dispatcher.dispatch(context, channel, event_config)
  end
end
