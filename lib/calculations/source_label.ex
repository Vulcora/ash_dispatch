defmodule AshDispatch.Calculations.SourceLabel do
  @moduledoc """
  Calculates a human-readable label for the source resource type.
  Uses UrlBuilder.resource_label/1 if available, else derives from module name.
  """

  use Ash.Resource.Calculation

  alias AshDispatch.{Config, EventResolver}

  @impl true
  def load(_query, _opts, _context), do: [:event_id, :source_type]

  @impl true
  def calculate(records, _opts, _context) do
    url_builder = Config.url_builder()
    Enum.map(records, &compute_source_label(&1, url_builder))
  end

  defp compute_source_label(record, url_builder) do
    # Use EventResolver for consistent event lookup and callback execution
    case get_data_key_from_event(record.event_id) do
      {:ok, data_key} ->
        get_label_from_url_builder(data_key, url_builder) ||
          derive_from_source_type(record.source_type)

      :error ->
        derive_from_source_type(record.source_type)
    end
  end

  # Use EventResolver for safe data_key callback execution
  defp get_data_key_from_event(event_id) do
    case EventResolver.find_module(event_id) do
      {:ok, module} ->
        case EventResolver.data_key(module) do
          key when is_atom(key) and not is_nil(key) -> {:ok, key}
          _ -> :error
        end

      {:error, :not_found} ->
        :error
    end
  end

  defp get_label_from_url_builder(_data_key, nil), do: nil

  defp get_label_from_url_builder(data_key, url_builder) do
    # url_builder is an app-specific module, not an event module
    # Keep using function_exported? for external modules
    if Code.ensure_loaded?(url_builder) && function_exported?(url_builder, :resource_label, 1) do
      try do
        url_builder.resource_label(data_key)
      rescue
        _ -> nil
      end
    end
  end

  defp derive_from_source_type(nil), do: nil

  defp derive_from_source_type(source_type) when is_binary(source_type) do
    source_type |> String.split(".") |> List.last()
  end
end
