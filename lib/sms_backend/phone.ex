defmodule AshDispatch.SMSBackend.Phone do
  @moduledoc """
  Normaliserar ett telefonnummer till E.164.

  Egen modul med egen testtabell, för det är den här funktionen som avgör om
  ett SMS når en människa eller tyst går till ingenting. Ett nummer som skrivs
  `070-123 45 67` i ett formulär, `0046701234567` i en import och
  `+46701234567` i ett API ska bli samma sträng innan det lämnar huset.

  ## Reglerna

      "070-123 45 67"    → "+46701234567"   # inledande 0 → landskod
      "0046 70 1234567"  → "+46701234567"   # 00 → +
      "+46701234567"     → "+46701234567"   # redan E.164
      "0701234567"       → "+46701234567"

      "123"              → :error           # för kort
      "08-12"            → :error
      nil                → :error

  ## Landskoden

  `:default_country_code` styr vad ett inledande `0` blir, och är `"46"` om
  inget sägs:

      config :ash_dispatch, :default_country_code, "47"

  Ett nummer som redan bär `+` eller `00` rörs inte — landskoden gäller bara
  det nationella formatet, där nollan ÄR utlandsprefixet som ska bort.
  """

  @doc """
  Returnerar `{:ok, e164}` eller `:error`.
  """
  @spec to_e164(String.t() | nil) :: {:ok, String.t()} | :error
  def to_e164(nil), do: :error

  def to_e164(raw) when is_binary(raw) do
    raw
    |> String.replace(~r/[\s\-().]/u, "")
    |> normalisera()
    |> validera()
  end

  def to_e164(_), do: :error

  defp normalisera("+" <> rest), do: "+" <> rest
  defp normalisera("00" <> rest), do: "+" <> rest
  defp normalisera("0" <> rest), do: "+" <> landskod() <> rest
  defp normalisera(other), do: other

  # E.164: plus, sedan 8–15 siffror, och den första får inte vara noll.
  defp validera("+" <> siffror = nummer) do
    if Regex.match?(~r/^[1-9]\d{7,14}$/, siffror), do: {:ok, nummer}, else: :error
  end

  defp validera(_), do: :error

  defp landskod, do: Application.get_env(:ash_dispatch, :default_country_code, "46")
end
