defmodule AshDispatch.Log do
  @moduledoc """
  Keeps people's addresses out of the log.

  A log is read by more people, kept longer and copied to more places than the
  data it describes. The library therefore writes a recipient as a masked form
  that is still enough to follow a delivery - `a***@example.com`, `***4567` -
  and never writes a subject line, which can say as much as the body.

  ## Configuration

      config :ash_dispatch, log_recipients: :redacted

  - `:redacted` (default) - masked as above.
  - `:none` - recipients are not written at all.
  - `:full` - recipients are written as they are. For local development, or
    for a log that is itself kept as carefully as the data.

  Every log line the library writes about a delivery also carries the receipt's
  id, which is what to search for.
  """

  @email ~r/([A-Za-z0-9._%+\-])[A-Za-z0-9._%+\-]*@([A-Za-z0-9.\-]+\.[A-Za-z]{2,})/
  @phone ~r/(?<![\w.\-])\+?\d[\d \-]{6,}\d(?![\w\-])/

  @doc """
  A recipient in the form the configuration allows. Takes what the transports
  pass around: an address, a `{name, address}` tuple, a list of either, or a map
  or struct that holds one.
  """
  @spec recipient(term) :: String.t()
  def recipient(value) do
    case mode() do
      :full -> full(value)
      :none -> "[recipient]"
      _redacted -> value |> full() |> redact_text()
    end
  end

  @doc """
  Text with every e-mail address and phone number in it masked, unless the
  configuration says `:full`. For error terms and provider answers, which quote
  the address back.
  """
  @spec redact_text(String.t()) :: String.t()
  def redact_text(text) when is_binary(text) do
    case mode() do
      :full ->
        text

      :none ->
        text
        |> then(&Regex.replace(@email, &1, "[recipient]"))
        |> then(&Regex.replace(@phone, &1, "[recipient]"))

      _redacted ->
        text
        |> then(&Regex.replace(@email, &1, "\\1***@\\2"))
        |> then(&Regex.replace(@phone, &1, fn number -> "***" <> last_digits(number) end))
    end
  end

  def redact_text(other), do: other |> inspect() |> redact_text()

  @doc "An error term as text, with addresses masked."
  @spec reason(term) :: String.t()
  def reason(term) when is_binary(term), do: redact_text(term)
  def reason(term), do: term |> inspect() |> redact_text()

  defp mode, do: Application.get_env(:ash_dispatch, :log_recipients, :redacted)

  defp full(value) when is_binary(value), do: value
  defp full({_name, address}) when is_binary(address), do: address
  defp full(values) when is_list(values), do: Enum.map_join(values, ", ", &full/1)

  defp full(%{} = value) do
    case Enum.find_value([:email, :phone, :phone_number, :address], &Map.get(value, &1)) do
      found when is_binary(found) -> found
      _ -> "[recipient]"
    end
  end

  defp full(_other), do: "[recipient]"

  defp last_digits(number) do
    number |> String.replace(~r/\D/, "") |> String.slice(-4, 4)
  end
end
