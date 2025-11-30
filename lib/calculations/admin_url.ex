defmodule AshDispatch.Calculations.AdminUrl do
  @moduledoc """
  Calculates admin-specific URL for source resource, regardless of receipt audience.

  Unlike `source_url` which uses the receipt's audience to determine the URL path,
  this calculation always uses `audience: :admin`. This is useful for admin dashboards
  that need to link to admin views regardless of who the notification was sent to.

  ## Configuration

      config :ash_dispatch, url_builder: MyApp.UrlBuilder

  The UrlBuilder must implement `build_resource_url/3` with support for `audience: :admin`.
  """

  use Ash.Resource.Calculation

  alias AshDispatch.{Config, EventResolver}

  @impl true
  def load(_query, _opts, _context), do: [:event_id, :source_type, :source_id]

  @impl true
  def calculate(records, _opts, _context) do
    url_builder = Config.url_builder()
    Enum.map(records, &compute_admin_url(&1, url_builder))
  end

  defp compute_admin_url(record, url_builder) do
    # Use EventResolver for consistent event lookup and callback execution
    with {:ok, event_module} <- EventResolver.find_module(record.event_id),
         {:ok, data_key} <- get_data_key(event_module),
         {:ok, source_id} <- get_source_id(record),
         true <- not is_nil(url_builder) do
      mock_resource = %{id: source_id}

      try do
        url_builder.build_resource_url(data_key, mock_resource, audience: :admin, path_only: true)
      rescue
        ArgumentError -> nil
      end
    else
      _ -> nil
    end
  end

  # Use EventResolver for safe data_key callback execution
  defp get_data_key(event_module) do
    case EventResolver.data_key(event_module) do
      key when is_atom(key) and not is_nil(key) -> {:ok, key}
      _ -> :error
    end
  end

  defp get_source_id(%{source_id: nil}), do: :error
  defp get_source_id(%{source_id: id}), do: {:ok, id}
end
