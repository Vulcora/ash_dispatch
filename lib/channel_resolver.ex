defmodule AshDispatch.ChannelResolver do
  @moduledoc """
  Centralized channel resolution for AshDispatch events.

  Handles the logic for determining which channels an event should dispatch to,
  with consistent priority rules across all parts of the system.

  ## Priority Rules

  Currently: **DSL channels take precedence** over module callback channels.

  1. If DSL channels are defined (via `dispatch` DSL on resources), use those
  2. Otherwise, fall back to `channels/1` callback on the event module

  This can be changed in the future to merge both sources if needed.

  ## Usage

      # With event config from DSL introspection
      channels = ChannelResolver.resolve(event_id, event_module, context,
        dsl_channels: event_config.channels
      )

      # Without pre-loaded DSL channels (will look them up)
      channels = ChannelResolver.resolve(event_id, event_module, context)

      # Just check if event has email channels
      has_email? = ChannelResolver.has_transport?(event_id, event_module, context, :email)
  """

  alias AshDispatch.{Channel, Config, Context}

  require Logger

  @doc """
  Resolve channels for an event.

  ## Options

  - `:dsl_channels` - Pre-loaded DSL channel configs (avoids lookup)
  - `:strategy` - Resolution strategy: `:dsl_first` (default) or `:merge`

  ## Returns

  List of `%AshDispatch.Channel{}` structs.
  """
  @spec resolve(String.t() | nil, module() | nil, Context.t(), keyword()) :: [Channel.t()]
  def resolve(event_id, event_module, context, opts \\ []) do
    strategy = Keyword.get(opts, :strategy, :dsl_first)
    dsl_channels = get_dsl_channels(event_id, opts)
    module_channels = get_module_channels(event_module, context)

    case strategy do
      :dsl_first ->
        # DSL channels take precedence, module is fallback
        if Enum.any?(dsl_channels) do
          dsl_channels
        else
          module_channels
        end

      :merge ->
        # Merge both sources (future option)
        # Could deduplicate by transport+audience if needed
        dsl_channels ++ module_channels
    end
  end

  @doc """
  Check if an event has channels of a specific transport type.

  Useful for filtering events to only those with email channels, etc.
  """
  @spec has_transport?(String.t() | nil, module() | nil, Context.t(), atom(), keyword()) ::
          boolean()
  def has_transport?(event_id, event_module, context, transport, opts \\ []) do
    event_id
    |> resolve(event_module, context, opts)
    |> Enum.any?(&(&1.transport == transport))
  end

  @doc """
  Get channels from DSL configuration only.

  Looks up channels defined via the `dispatch` DSL on resources.
  """
  @spec get_dsl_channels(String.t() | nil, keyword()) :: [Channel.t()]
  def get_dsl_channels(nil, _opts), do: []

  def get_dsl_channels(event_id, opts) do
    # Use pre-loaded channels if provided
    case Keyword.fetch(opts, :dsl_channels) do
      {:ok, channels} when is_list(channels) ->
        Enum.map(channels, &to_channel_struct/1)

      _ ->
        # Look up from configured domains
        lookup_dsl_channels(event_id)
    end
  end

  @doc """
  Get channels from event module callback only.

  Calls the `channels/1` callback on the event module if it exists.
  """
  @spec get_module_channels(module() | nil, Context.t()) :: [Channel.t()]
  def get_module_channels(nil, _context), do: []

  def get_module_channels(event_module, context) do
    if function_exported?(event_module, :channels, 1) do
      try do
        event_module.channels(context)
      rescue
        error ->
          Logger.debug(
            "[ChannelResolver] Failed to get channels from #{inspect(event_module)}: #{inspect(error)}"
          )

          []
      end
    else
      []
    end
  end

  @doc """
  Convert various channel formats to a Channel struct.

  Handles:
  - `%AshDispatch.Channel{}` - returned as-is
  - `%AshDispatch.Dsl.Channel{}` - converted to runtime Channel
  - Maps with channel fields
  - Keyword lists with channel fields
  """
  @spec to_channel_struct(term()) :: Channel.t()
  def to_channel_struct(%Channel{} = channel), do: channel

  def to_channel_struct(%AshDispatch.Dsl.Channel{} = dsl_channel) do
    %Channel{
      transport: dsl_channel.transport,
      audience: dsl_channel.audience,
      time: dsl_channel.time || {:in, 0},
      policy: dsl_channel.policy || :always,
      variant: dsl_channel.variant,
      webhook_url: dsl_channel.webhook_url,
      deduplicate_group: dsl_channel.deduplicate_group,
      optional: dsl_channel.optional || false,
      content: dsl_channel.content || %{},
      metadata: dsl_channel.metadata || %{},
      opts: dsl_channel.opts || %{},
      load: dsl_channel.load || []
    }
  end

  def to_channel_struct(channel) when is_map(channel) do
    %Channel{
      transport: Map.fetch!(channel, :transport),
      audience: Map.fetch!(channel, :audience),
      time: extract_time(channel),
      policy: Map.get(channel, :policy, :always),
      variant: Map.get(channel, :variant),
      webhook_url: Map.get(channel, :webhook_url),
      deduplicate_group: Map.get(channel, :deduplicate_group),
      optional: Map.get(channel, :optional, false),
      content: Map.get(channel, :content, %{}) |> to_map(),
      metadata: Map.get(channel, :metadata, %{}) |> to_map(),
      opts: Map.get(channel, :opts, %{}),
      load: Map.get(channel, :load, [])
    }
  end

  def to_channel_struct(channel) when is_list(channel) do
    %Channel{
      transport: Keyword.fetch!(channel, :transport),
      audience: Keyword.fetch!(channel, :audience),
      time: extract_time(channel),
      policy: Keyword.get(channel, :policy, :always),
      variant: Keyword.get(channel, :variant),
      webhook_url: Keyword.get(channel, :webhook_url),
      deduplicate_group: Keyword.get(channel, :deduplicate_group),
      optional: Keyword.get(channel, :optional, false),
      content: Keyword.get(channel, :content, []) |> to_map(),
      metadata: Keyword.get(channel, :metadata, []) |> to_map(),
      opts: Keyword.get(channel, :opts, %{}),
      load: Keyword.get(channel, :load, [])
    }
  end

  # Private helpers

  defp lookup_dsl_channels(event_id) do
    domains = Config.domains()

    result =
      Enum.find_value(domains, fn domain ->
        try do
          domain
          |> Ash.Domain.Info.resources()
          |> Enum.find_value(fn resource ->
            if AshDispatch.Resource.Info.dispatch_enabled?(resource) do
              resource
              |> AshDispatch.Resource.Info.events()
              |> Enum.find(fn event -> event.event_id == event_id end)
              |> case do
                nil -> nil
                event -> event.channels
              end
            else
              nil
            end
          end)
        rescue
          _ -> nil
        end
      end)

    case result do
      channels when is_list(channels) ->
        Enum.map(channels, &to_channel_struct/1)

      _ ->
        []
    end
  end

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

  defp to_map(value) when is_list(value), do: Enum.into(value, %{})
  defp to_map(value) when is_map(value), do: value
  defp to_map(_), do: %{}
end
