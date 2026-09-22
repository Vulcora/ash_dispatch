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
  @textbarande [":in_app", ":discord", ":slack", ":sms", ":webhook", ":push"]

  defp grenar do
    [_, body] = String.split(@dispatcher, "defp build_inline_content(", parts: 2)
    [body, _] = String.split(body, "\n  defp ", parts: 2)

    # Split on the branch heads so each transport is checked on its own. A test
    # reading the whole body would stay green as long as ANY branch read it.
    Regex.split(~r/^\s{8}(?=:[a-z_]+ ->)/m, body, trim: true)
    |> Enum.map(fn del ->
      case Regex.run(~r/^\s*(:[a-z_]+) ->/, del) do
        [_, namn] -> {namn, del}
        _ -> {nil, del}
      end
    end)
    |> Enum.filter(fn {namn, _} -> namn != nil end)
    |> Map.new()
  end

  test "provet hittar grenarna alls" do
    # Without this line the whole file goes green because the regex stopped
    # matching.
    funna = Map.keys(grenar())
    assert length(funna) >= 6, "hittade bara #{inspect(funna)}"
    for t <- @textbarande, do: assert(Map.has_key?(grenar(), t), "grenen #{t} saknas")
  end

  test "GUARD: every body-carrying transport reads content_config[:message]" do
    g = grenar()

    utan =
      Enum.filter(@textbarande, fn t ->
        not (g[t] =~ "content_config[:message]")
      end)

    assert utan == [],
           """
           These transport branches build content without reading the body from the DSL:

             #{Enum.join(utan, ", ")}

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
    # `interpolate(nil, _)` ger `nil`. En literal `message:` i map-syntax
    # therefore writes `nil` over the module's callback text in hybrid mode —
    # the same class of bug as above, in the other direction.
    g = grenar()

    fel =
      Enum.filter(@textbarande, fn t ->
        Regex.match?(~r/^\s*message:\s/m, g[t])
      end)

    assert fel == [],
           """
           These branches set `message:` unconditionally:

             #{Enum.join(fel, ", ")}

           When the DSL omits the body the value is `nil`, and `Map.merge` in
           `build_content/5` then overwrites the module's callback with nothing.
           Use `maybe_put/3`, which skips nil.
           """
  end

  test "webhook carries the title too — a receiver rendering a card needs it" do
    assert grenar()[":webhook"] =~ "content_config[:title]"
  end

  test "webhook keeps payload and url" do
    # The fix must not have dropped what the branch already did.
    g = grenar()[":webhook"]
    assert g =~ "content_config[:webhook_payload]"
    assert g =~ "channel.webhook_url"
  end

  # Transports whose receiver can RENDER a way onward. `:discord`, `:slack`
  # and `:sms` are deliberately out: their payloads have no button shape of
  # their own, and a url without a surface that shows it is a key that only
  # looks like it does something.
  @vagbarande [":in_app", ":webhook", ":push"]

  test "GUARD: every transport with a way onward reads content_config[:action_url]" do
    g = grenar()

    utan = Enum.filter(@vagbarande, fn t -> not (g[t] =~ "content_config[:action_url]") end)

    assert utan == [],
           """
           These branches build content without reading the way onward from the DSL:

             #{Enum.join(utan, ", ")}

           A declared `action_url:` then becomes DECORATION: the recipient
           learns something happened but has no way to get there, and the
           sender cannot notice except by reading what arrived. `:webhook` was
           exactly that case until 0.7.3 — one consumer reported their channel
           posts as "dead notifications".
           """
  end

  test "webhook carries the button label too — a url without words becomes a button named \"Open\"" do
    assert grenar()[":webhook"] =~ "content_config[:action_label]"
  end
end
