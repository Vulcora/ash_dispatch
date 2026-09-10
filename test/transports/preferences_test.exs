defmodule AshDispatch.Transports.PreferencesTest do
  @moduledoc """
  The opt-out gate.

  The test that matters is the enumeration: EVERY transport that reaches a
  person must ask. Until 0.7.0 four of seven did not, and a preference
  honoured on one channel was silently ignored on another — invisible to the
  person who set it.

  The check reads the compiled source rather than a list someone maintains,
  because a list someone maintains is exactly what went stale.
  """
  use ExUnit.Case, async: true

  alias AshDispatch.Transports.Preferences

  # Transports that deliver to a HUMAN. `:oban` and `:broadcast` are
  # machinery — there is no person to ask.
  @till_manniska ~w(email in_app webhook slack discord sms push)

  defp kalla(namn), do: File.read!("lib/transports/#{namn}.ex")

  test "the enumeration is not empty" do
    # Without this line the whole guard is green by matching nothing.
    assert length(@till_manniska) >= 7
    for t <- @till_manniska, do: assert(File.exists?("lib/transports/#{t}.ex"), "#{t}.ex missing")
  end

  test "EVERY human-facing transport asks about consent" do
    utan =
      Enum.reject(@till_manniska, fn t ->
        src = kalla(t)
        String.contains?(src, "with_consent") or String.contains?(src, "allows_receipt?")
      end)

    assert utan == [], """
    These transports deliver to a person without checking whether that person
    opted out:

      #{inspect(utan)}

    A preference honoured on one channel and ignored on another is worse than
    no preference at all — the person believes they turned it off.
    """
  end

  # The skip reason must be one string, or a dashboard filtering on it misses
  # whichever transport spelled it differently.
  test "the skip reason comes from one place" do
    assert Preferences.reason() == "user_opted_out"

    egna =
      Enum.filter(@till_manniska, fn t ->
        src = kalla(t)
        # A literal is allowed only where the shared function is not used at all.
        String.contains?(src, ~s("user_opted_out")) and String.contains?(src, "with_consent")
      end)

    assert egna == [], "these both use the gate AND spell the reason themselves: #{inspect(egna)}"
  end

  # `:oban` and `:broadcast` have no person to ask, and adding the gate there
  # would suggest there is one.
  test "machinery transports are deliberately outside the rule" do
    for maskin <- ~w(oban broadcast) do
      refute String.contains?(kalla(maskin), "with_consent"),
             "#{maskin} is machinery — a consent gate there implies a recipient that does not exist"
    end
  end
end
