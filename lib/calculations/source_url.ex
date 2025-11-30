defmodule AshDispatch.Calculations.SourceUrl do
  @moduledoc """
  Calculates the source URL for a delivery receipt at runtime.

  This calculation looks up the event module from configuration and calls
  its `source_url/2` callback with a reconstructed context and channel.

  The URL is computed at runtime (not persisted) because it may depend on
  who is viewing it (admin vs user paths differ).

  ## Requirements for source_url to work

  For an event to have working source URLs on delivery receipts, the event
  module must define the `data_key/0` callback:

      @impl true
      def data_key, do: :order  # or :ticket, :user, etc.

  The data_key tells the calculation which key to use when reconstructing
  the context for URL generation. Without it, source_url will return nil.

  See `AshDispatch.Event` documentation for more details.
  """

  use Ash.Resource.Calculation

  alias AshDispatch.EventResolver

  require Logger

  @impl true
  def load(_query, _opts, _context) do
    [:event_id, :audience, :source_type, :source_id]
  end

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, fn record ->
      compute_source_url(record)
    end)
  end

  defp compute_source_url(record) do
    # Use EventResolver for consistent event lookup and callback execution
    with {:ok, event_module} <- EventResolver.find_module(record.event_id),
         true <- EventResolver.exports?(event_module, :source_url, 2),
         {:ok, source_id} <- get_source_id(record),
         {:ok, _source_type} <- get_source_type(record),
         {:ok, data_key} <- get_data_key(event_module, record.event_id) do
      # Build a mock resource with just the id for URL generation
      mock_resource = %{id: source_id}

      # Reconstruct minimal context with the resource under its data_key
      context = %AshDispatch.Context{
        event_id: record.event_id,
        data: Map.put(%{}, data_key, mock_resource),
        resource_key: data_key,
        variables: %{},
        metadata: %{}
      }

      channel = %AshDispatch.Channel{
        transport: record.transport,
        audience: record.audience
      }

      # Use EventResolver for safe callback execution
      EventResolver.source_url(event_module, context, channel)
    else
      {:error, :missing_data_key, event_id} ->
        Logger.warning("""
        [AshDispatch] Cannot compute source_url for event "#{event_id}"

        The event module is missing a `data_key/0` callback. Add it to enable
        source resource linking on delivery receipts:

            @impl true
            def data_key, do: :order  # or :ticket, :user, etc.

        The data_key should match the key used in context.data when dispatching.
        """)

        nil

      _ ->
        nil
    end
  end

  # Get data_key from event module using EventResolver, warning if missing
  defp get_data_key(event_module, event_id) do
    case EventResolver.data_key(event_module) do
      nil -> {:error, :missing_data_key, event_id}
      key when is_atom(key) -> {:ok, key}
      _ -> {:error, :missing_data_key, event_id}
    end
  end

  defp get_source_id(%{source_id: nil}), do: :error
  defp get_source_id(%{source_id: id}), do: {:ok, id}

  defp get_source_type(%{source_type: nil}), do: :error
  defp get_source_type(%{source_type: type}), do: {:ok, type}
end
