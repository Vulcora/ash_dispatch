defmodule AshDispatch.Changes.DispatchEvent do
  @moduledoc """
  Ash.Resource.Change that dispatches an event after an action succeeds.

  Supports two modes:

  ## 1. DSL-Based Events (Transformer-Injected)

  This change is automatically injected by the
  `AshDispatch.Resource.Transformers.InjectDispatchChanges` transformer.

      # In resource DSL:
      dispatch do
        event :created, trigger_on: :create, ...
      end

      # Transformer injects:
      change {AshDispatch.Changes.DispatchEvent,
              event_id: "product_order.created",
              load: [:user],
              event_config: %{...}}

  ## 2. Standalone Event Modules (Manual Usage)

  For standalone event modules that use `AshDispatch.Event` behaviour:

      # In resource action:
      change {AshDispatch.Changes.DispatchEvent,
              event_id: "orders.created",
              data_key: :order,
              load: [:user, product_order_items: :product]}

  ## Options

  - `event_id` - The event ID (required)
  - `load` - List of relationships to preload (optional)
  - `event_config` - Map for DSL-based events (optional for mode 1)
  - `data_key` - Atom key for standalone modules (required for mode 2)
  """

  use Ash.Resource.Change

  alias AshDispatch.{Context, Channel, Dispatcher}
  alias Ash.Changeset

  require Logger

  @impl true
  def init(opts) do
    # Validate based on mode
    case Keyword.fetch(opts, :event_config) do
      {:ok, _} ->
        # DSL-based mode
        validate_dsl_mode(opts)

      :error ->
        # Standalone module mode
        validate_standalone_mode(opts)
    end
  end

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

  defp validate_dsl_mode(opts) do
    case Keyword.fetch(opts, :event_id) do
      {:ok, event_id} when is_binary(event_id) -> {:ok, opts}
      {:ok, _} -> {:error, "event_id must be a string"}
      :error -> {:error, "event_id is required"}
    end
  end

  defp validate_standalone_mode(opts) do
    with {:ok, event_id} when is_binary(event_id) <- Keyword.fetch(opts, :event_id),
         {:ok, data_key} when is_atom(data_key) <- Keyword.fetch(opts, :data_key) do
      {:ok, opts}
    else
      {:ok, _} -> {:error, "event_id must be a string and data_key must be an atom"}
      :error -> {:error, "event_id and data_key are required for standalone mode"}
    end
  end

  defp dispatch_event(changeset, record, opts, ash_context) do
    # Detect mode based on presence of event_config
    case Keyword.fetch(opts, :event_config) do
      {:ok, event_config} ->
        dispatch_dsl_event(changeset, record, opts, ash_context, event_config)

      :error ->
        dispatch_standalone_event(changeset, record, opts, ash_context)
    end
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

  # DSL-based event dispatch (original logic)
  defp dispatch_dsl_event(changeset, record, opts, ash_context, event_config) do
    event_id = Keyword.fetch!(opts, :event_id)
    load = Keyword.get(opts, :load, [])
    data_key = Map.get(event_config, :data_key)
    event_module = Map.get(event_config, :module)

    Logger.debug("[DispatchEvent] dispatch_dsl_event starting for event_id: #{event_id}")

    # Load relationships if specified
    record = maybe_load_relationships(record, load, changeset)

    # Build base context with the record
    context = build_context(event_id, record, changeset, ash_context, data_key)

    # Call prepare_data if event module defines it (non-default implementation)
    # This allows events to enrich context.data with additional data (e.g., created_user)
    context = maybe_enrich_context_with_prepare_data(context, changeset, record, event_module)

    Logger.debug("[DispatchEvent] built context: #{inspect(context)}")

    # Get channels (from module or inline config)
    channels = resolve_channels(context, event_config)
    Logger.debug("[DispatchEvent] resolved #{length(channels)} channels: #{inspect(channels)}")

    # Dispatch to all channels
    Enum.each(channels, fn channel ->
      Logger.debug("[DispatchEvent] dispatching to channel: #{inspect(channel)}")
      dispatch_to_channel(context, channel, event_config)
    end)

    Logger.debug("[DispatchEvent] dispatch_dsl_event completed for event_id: #{event_id}")
    :ok
  end

  # Standalone event module dispatch (new logic for Magasin-style events)
  defp dispatch_standalone_event(changeset, record, opts, _ash_context) do
    event_id = Keyword.fetch!(opts, :event_id)
    data_key = Keyword.fetch!(opts, :data_key)
    load = Keyword.get(opts, :load, [])

    # Load relationships if specified
    record = maybe_load_relationships(record, load, changeset)

    # Get event module and call prepare_data if it exists
    event_modules = Application.get_env(:ash_dispatch, :event_modules, [])

    data =
      case Enum.find(event_modules, fn {id, _module} -> id == event_id end) do
        {^event_id, event_module} ->
          # Call prepare_data (may return empty map from default implementation)
          prepared_data = event_module.prepare_data(changeset, record)

          # If prepare_data returns empty map, use default behavior
          if map_size(prepared_data) == 0 do
            Map.put(%{}, data_key, record)
          else
            prepared_data
          end

        _ ->
          # Fallback if event not found in config
          Map.put(%{}, data_key, record)
      end

    # Dispatch using standalone event module API
    case Dispatcher.dispatch(event_id, data) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to dispatch standalone event #{event_id}: #{inspect(reason)}")
        :ok
    end
  end

  defp maybe_load_relationships(record, [], _changeset), do: record

  defp maybe_load_relationships(record, load, changeset) do
    # Use Ash.load! to load relationships
    domain = changeset.domain || record.__struct__.__domain__()

    case Ash.load(record, load, domain: domain, authorize?: false) do
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

  defp build_context(event_id, record, changeset, ash_context, data_key) do
    # Use data_key if provided, otherwise fall back to table name
    resource_key = data_key || record.__struct__.__schema__(:source)

    %Context{
      event_id: event_id,
      data: %{resource_key => record},
      resource_key: resource_key,
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

  # Call prepare_data on event module if it exists and returns non-empty data
  # This allows events to enrich context.data with additional data from the changeset
  # (e.g., a user created in a prior change step stored in changeset.context)
  defp maybe_enrich_context_with_prepare_data(context, _changeset, _record, nil), do: context

  defp maybe_enrich_context_with_prepare_data(context, changeset, record, event_module) do
    # Call prepare_data - it receives changeset and record
    prepared_data = event_module.prepare_data(changeset, record)

    # Merge prepared data into context.data if non-empty
    if map_size(prepared_data) > 0 do
      %{context | data: Map.merge(context.data, prepared_data)}
    else
      context
    end
  rescue
    error ->
      Logger.warning("""
      Failed to call prepare_data on #{inspect(event_module)}
      Error: #{inspect(error)}
      Continuing with base context...
      """)

      context
  end

  defp get_base_url do
    # Priority order:
    # 1. Configured endpoint module (calls Endpoint.url())
    # 2. PHX_HOST environment variable
    # 3. Explicit base_url config (deprecated)
    # 4. Fallback to localhost
    cond do
      endpoint = Application.get_env(:ash_dispatch, :endpoint) ->
        endpoint.url()

      host = System.get_env("PHX_HOST") ->
        scheme = System.get_env("PHX_SCHEME", "https")
        port = System.get_env("PHX_PORT", "443")

        case {scheme, port} do
          {"https", "443"} -> "#{scheme}://#{host}"
          {"http", "80"} -> "#{scheme}://#{host}"
          _ -> "#{scheme}://#{host}:#{port}"
        end

      base_url = Application.get_env(:ash_dispatch, :base_url) ->
        base_url

      true ->
        "http://localhost:4000"
    end
  end

  defp resolve_channels(_context, %{channels: channels}) when not is_nil(channels) do
    # Inline DSL channels take precedence (for hybrid mode)
    # Convert inline channel configs to Channel structs
    Enum.map(channels, &channel_config_to_struct/1)
  end

  defp resolve_channels(context, %{module: module}) when not is_nil(module) do
    # Fall back to module callback if no inline channels
    module.channels(context)
  end

  defp channel_config_to_struct(channel) when is_map(channel) do
    %Channel{
      transport: Map.fetch!(channel, :transport),
      audience: Map.fetch!(channel, :audience),
      time: extract_time(channel),
      policy: Map.get(channel, :policy, :always),
      variant: Map.get(channel, :variant),
      webhook_url: Map.get(channel, :webhook_url),
      content: Map.get(channel, :content, %{}) |> Enum.into(%{}),
      metadata: Map.get(channel, :metadata, %{}) |> Enum.into(%{}),
      opts: Map.get(channel, :opts, %{}),
      load: Map.get(channel, :load, [])
    }
  end

  defp channel_config_to_struct(channel) when is_list(channel) do
    %Channel{
      transport: Keyword.fetch!(channel, :transport),
      audience: Keyword.fetch!(channel, :audience),
      time: extract_time(channel),
      policy: Keyword.get(channel, :policy, :always),
      variant: Keyword.get(channel, :variant),
      webhook_url: Keyword.get(channel, :webhook_url),
      content: Keyword.get(channel, :content, []) |> Enum.into(%{}),
      metadata: Keyword.get(channel, :metadata, []) |> Enum.into(%{}),
      opts: Keyword.get(channel, :opts, %{}),
      load: Keyword.get(channel, :load, [])
    }
  end

  # Extract time from channel config - supports both :time and :delay keys
  defp extract_time(channel) when is_map(channel) do
    case Map.get(channel, :time) || Map.get(channel, :delay) do
      nil -> {:in, 0}
      {:in, _} = time -> time
      {:at, _} = time -> time
      seconds when is_integer(seconds) -> {:in, seconds}
      _ -> {:in, 0}
    end
  end

  defp extract_time(channel) when is_list(channel) do
    case Keyword.get(channel, :time) || Keyword.get(channel, :delay) do
      nil -> {:in, 0}
      {:in, _} = time -> time
      {:at, _} = time -> time
      seconds when is_integer(seconds) -> {:in, seconds}
      _ -> {:in, 0}
    end
  end

  defp dispatch_to_channel(context, channel, event_config) do
    # Delegate to Dispatcher module which handles:
    # - Creating DeliveryReceipt
    # - Dispatching to appropriate transport
    # - Updating receipt status
    Dispatcher.dispatch_channel(context, channel, event_config)
  end
end
