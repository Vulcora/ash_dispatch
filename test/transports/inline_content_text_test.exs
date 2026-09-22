defmodule AshDispatch.Transports.InlineContentTextTest do
  @moduledoc """
  Every transport that CARRIES a body must also READ it from the DSL.

  ## The bug this guard exists for

  The `:webhook` branch of `build_inline_content/4` built only `payload` and
  `webhook_url`. It never read `content_config[:message]` — the only one of
  six branches that did not.

  The consequence was silent, and that is the whole point. An event WITH an
  event module falls back on the module's `notification_message/2`, whose
  generated default is `"You have a new notification"`. The merge order in
  `build_content/5` lets the module's value stand for every key inline content
  does not set, so a declared `content: [message: ...]` became decoration and
  the recipient got the placeholder — the right shape with the wrong content.

  Measured at a consumer before the fix: **41 of 41** delivered webhook
  receipts carried the placeholder, across nine declared channels. None of the
  written text had ever arrived. That one half were channel posts and the
  other personal DMs made no difference; it was the transport, not the event.

  ## Why this test reads the source

  Dispatch has no lightweight harness here — the same reason `push_test.exs`
  spells out. But a STRUCTURAL test that only asks "does the branch exist?"
  was exactly what was there, and it saw a branch carrying the wrong content
  as a branch that existed. This guard therefore asks what the branch DOES.
  """

  use ExUnit.Case, async: true

  @dispatcher File.read!("lib/dispatcher.ex")

  # Transports whose content IS a body of text. `:email` is deliberately out:
  # it carries `subject` + `html_body` + `text_body` and has no `message`.
  @text_bearing [":in_app", ":discord", ":slack", ":sms", ":webhook", ":push"]

  defp branches do
    [_, body] = String.split(@dispatcher, "defp build_inline_content(", parts: 2)
    [body, _] = String.split(body, "\n  defp ", parts: 2)

    # Split on the branch heads so each transport is checked on its own. A test
    # reading the whole body would stay green as long as ANY branch read it.
    Regex.split(~r/^\s{8}(?=:[a-z_]+ ->)/m, body, trim: true)
    |> Enum.map(fn part ->
      case Regex.run(~r/^\s*(:[a-z_]+) ->/, part) do
        [_, name] -> {name, part}
        _ -> {nil, part}
      end
    end)
    |> Enum.filter(fn {name, _} -> name != nil end)
    |> Map.new()
  end

  test "the split finds the branches at all" do
    # Without this line the whole file goes green because the regex stopped
    # matching.
    found = Map.keys(branches())
    assert length(found) >= 6, "found only #{inspect(found)}"
    for t <- @text_bearing, do: assert(Map.has_key?(branches(), t), "branch #{t} is missing")
  end

  test "GUARD: every body-carrying transport reads content_config[:message]" do
    g = branches()

    missing =
      Enum.filter(@text_bearing, fn t ->
        not (g[t] =~ "content_config[:message]")
      end)

    assert missing == [],
           """
           These transport branches build content without reading the body from the DSL:

             #{Enum.join(missing, ", ")}

           A `content: [message: ...]` on such a channel becomes DECORATION. If
           the event has a module, the generated default from
           `notification_message/2` is sent instead — "You have a new
           notification" — and the recipient cannot tell it from a real message.

           Add to the branch:

               |> maybe_put(
                 :message,
                 interpolate(
                   content_config[:message] || content_config[:notification_message],
                   context
                 )
               )
           """
  end

  test "GUARD: the body is set with maybe_put, never as an unconditional key" do
    # `interpolate(nil, _)` returns `nil`. A literal `message:` in map syntax
    # therefore writes `nil` over the module's callback text in hybrid mode —
    # the same class of bug as above, in the other direction.
    g = branches()

    offenders =
      Enum.filter(@text_bearing, fn t ->
        Regex.match?(~r/^\s*message:\s/m, g[t])
      end)

    assert offenders == [],
           """
           These branches set `message:` unconditionally:

             #{Enum.join(offenders, ", ")}

           When the DSL omits the body the value is `nil`, and `Map.merge` in
           `build_content/5` then overwrites the module's callback with nothing.
           Use `maybe_put/3`, which skips nil.
           """
  end

  test "webhook carries the title too — a receiver rendering a card needs it" do
    assert branches()[":webhook"] =~ "content_config[:title]"
  end

  test "webhook keeps payload and url" do
    # The fix must not have dropped what the branch already did.
    g = branches()[":webhook"]
    assert g =~ "content_config[:webhook_payload]"
    assert g =~ "channel.webhook_url"
  end

  # Transports whose receiver can RENDER a way onward. `:discord`, `:slack`
  # and `:sms` are deliberately out: their payloads have no button shape of
  # their own, and a url without a surface that shows it is a key that only
  # looks like it does something.
  @action_bearing [":in_app", ":webhook", ":push"]

  test "GUARD: every transport with a way onward reads content_config[:action_url]" do
    g = branches()

    missing =
      Enum.filter(@action_bearing, fn t -> not (g[t] =~ "content_config[:action_url]") end)

    assert missing == [],
           """
           These branches build content without reading the way onward from the DSL:

             #{Enum.join(missing, ", ")}

           A declared `action_url:` then becomes DECORATION: the recipient
           learns something happened but has no way to get there, and the
           sender cannot notice except by reading what arrived. `:webhook` was
           exactly that case until 0.7.3 — one consumer reported their channel
           posts as "dead notifications".
           """
  end

  test "webhook carries the button label too — a url without words becomes a button named \"Open\"" do
    assert branches()[":webhook"] =~ "content_config[:action_label]"
  end
end
