defmodule AshDispatch.SMSBackend.Phone do
  @moduledoc """
  Normalises a phone number to E.164.

  Its own module with its own test table, because this function decides
  whether a message reaches a person or goes quietly nowhere. A number typed
  `070-123 45 67` in a form, `0046701234567` in an import and `+46701234567`
  by an API has to become the same string before it leaves the app.

  ## The rules

      "070-123 45 67"    → "+46701234567"   # leading 0 → country code
      "0046 70 1234567"  → "+46701234567"   # 00 → +
      "+46701234567"     → "+46701234567"   # already E.164
      "0701234567"       → "+46701234567"

      "123"              → :error           # too short
      "08-12"            → :error
      nil                → :error

  ## The country code

  `:default_country_code` decides what a leading `0` becomes. It defaults to
  `"46"`:

      config :ash_dispatch, :default_country_code, "47"

  A number that already carries `+` or `00` is left alone — the country code
  applies only to the national format, where the zero IS the trunk prefix
  being replaced.
  """

  @doc """
  Returns `{:ok, e164}` or `:error`.
  """
  @spec to_e164(String.t() | nil) :: {:ok, String.t()} | :error
  def to_e164(nil), do: :error

  def to_e164(raw) when is_binary(raw) do
    raw
    |> String.replace(~r/[\s\-().]/u, "")
    |> normalise()
    |> validate()
  end

  def to_e164(_), do: :error

  defp normalise("+" <> rest), do: "+" <> rest
  defp normalise("00" <> rest), do: "+" <> rest
  defp normalise("0" <> rest), do: "+" <> country_code() <> rest
  defp normalise(other), do: other

  # E.164: a plus, then 8–15 digits, and the first one may not be zero.
  defp validate("+" <> digits = number) do
    if Regex.match?(~r/^[1-9]\d{7,14}$/, digits), do: {:ok, number}, else: :error
  end

  defp validate(_), do: :error

  defp country_code, do: Application.get_env(:ash_dispatch, :default_country_code, "46")
end
