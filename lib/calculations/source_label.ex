defmodule AshDispatch.Calculations.SourceLabel do
  @moduledoc """
  Calculates a human-readable label for the source resource type.
  Uses UrlBuilder.resource_label/1 if available, else derives from module name.
  """

  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:event_id, :source_type]

  @impl true
  def calculate(records, _opts, _context) do
    event_modules = Application.get_env(:ash_dispatch, :event_modules, [])
    url_builder = Application.get_env(:ash_dispatch, :url_builder)
    Enum.map(records, &compute_source_label(&1, event_modules, url_builder))
  end

  defp compute_source_label(record, event_modules, url_builder) do
    case get_data_key_from_event(record.event_id, event_modules) do
      {:ok, data_key} ->
        get_label_from_url_builder(data_key, url_builder) ||
          derive_from_source_type(record.source_type)

      :error ->
        derive_from_source_type(record.source_type)
    end
  end

  defp get_data_key_from_event(event_id, event_modules) do
    case Enum.find(event_modules, fn {id, _} -> id == event_id end) do
      {_, module} ->
        if function_exported?(module, :data_key, 0) do
          case module.data_key() do
            key when is_atom(key) and not is_nil(key) -> {:ok, key}
            _ -> :error
          end
        else
          :error
        end

      nil ->
        :error
    end
  end

  defp get_label_from_url_builder(_data_key, nil), do: nil

  defp get_label_from_url_builder(data_key, url_builder) do
    if function_exported?(url_builder, :resource_label, 1) do
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
