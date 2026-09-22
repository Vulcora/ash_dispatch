defmodule AshDispatch.Transports.WebhookModuleContentTest do
  @moduledoc """
  What a MODULE-BASED event may contribute to a webhook.

  ## The bug this test exists for

  `build_module_content/5` had a branch per transport, and `:webhook` fell
  through to the catch-all — `%{message: notification_message(...)}` and
  nothing else. A module-based webhook event therefore could not set a title,
  nor a way onward, however much it wanted to: `notification_title/2` and
  `action_url/2` were never called for that transport.

  `:in_app` has always carried all four. That `:webhook` did not was no
  declaration — it was that nobody had written the branch.

  Measured at a consumer on 2026-09-14: of six distinct channel posts in
  production, ONE carried a title and NONE carried a link. The team read that
  as carelessness; the path did not exist.

  ## `extra_content/2`

  A transport's content is a closed list, and that is enough while the
  receiver is a notification list. It is not enough when the receiver is a
  Slack surface that can render facts in two columns, several buttons and an
  icon — without this, every new key of that kind is a change to the library.

  The test below guards the rule that makes the addition harmless: the
  transport's own keys WIN. A module returning `%{message: ...}` in the
  addition must not be able to silence `notification_message/2`.
  """

  use ExUnit.Case, async: true

  alias AshDispatch.{Channel, Context}

  @dispatcher File.read!("lib/dispatcher.ex")

  defp module_content_body do
    [_, body] = String.split(@dispatcher, "defp build_module_content(", parts: 2)
    [body, _] = String.split(body, "\n  defp ", parts: 2)
    body
  end

  defp webhook_branch do
    body = module_content_body()
    [_, gren] = String.split(body, ":webhook ->", parts: 2)
    [gren, _] = String.split(gren, "\n        _ ->", parts: 2)
    gren
  end

  test "the test finds the branch at all" do
    # Without this line the whole file goes green because the regex stopped
    # matching.
    assert module_content_body() =~ ":webhook ->"
  end

  test "GUARD: the webhook branch carries the same four keys as :in_app" do
    branch = webhook_branch()

    for {key, callback} <- [
          {"title", "notification_title"},
          {"message", "notification_message"},
          {"action_url", "action_url"},
          {"action_label", "action_label"}
        ] do
      assert branch =~ "#{key}: module.#{callback}(",
             """
             `:webhook` builds content without `#{key}`.

             A module-based event then cannot set it — `#{callback}/2` is never
             called for this transport, and the sender has no way to notice
             except by reading what arrived.
             """
    end
  end

  test "GUARD: extra_content is merged BELOW the transport's keys" do
    body = module_content_body()

    assert body =~ "EventResolver.extra_content(",
           "the module's own keys are never fetched"

    # The order IS the rule. `Map.merge(extra, transport_content)` lets the
    # transport win; swap them and an addition can silence `message`, and the
    # silent surface is back in a new form.
    [_, after_call] = String.split(body, "EventResolver.extra_content(", parts: 2)

    assert after_call =~ ~r/Map\.merge\(extra\).*Map\.merge\(transport_content\)/s,
           """
           The addition must be merged BEFORE the transport's content, so the
           transport's keys win. Otherwise `extra_content/2` can overwrite
           `message` — and whoever debugs it goes looking for text that
           `notification_message/2` did in fact return.
           """
  end

  describe "EventResolver.extra_content/3" do
    setup do
      %{
        context: %Context{event_id: "t", data: %{}, metadata: %{}},
        channel: %Channel{transport: :webhook, audience: :slack_channel}
      }
    end

    test "a module without the callback gives an empty map", %{context: c, channel: ch} do
      defmodule WithoutExtra do
      end

      assert AshDispatch.EventResolver.extra_content(WithoutExtra, c, ch) == %{}
    end

    test "the module's map comes through", %{context: c, channel: ch} do
      defmodule WithExtra do
        def extra_content(_c, _ch), do: %{slack_icon: "contract", slack_fields: [%{label: "A"}]}
      end

      assert AshDispatch.EventResolver.extra_content(WithExtra, c, ch) == %{
               slack_icon: "contract",
               slack_fields: [%{label: "A"}]
             }
    end

    test "anything that is not a map is ignored — a missing notification costs more", %{
      context: c,
      channel: ch
    } do
      defmodule WrongTypeExtra do
        def extra_content(_c, _ch), do: [:not, :a, :map]
      end

      assert AshDispatch.EventResolver.extra_content(WrongTypeExtra, c, ch) == %{}
    end

    @tag :capture_log
    test "a callback that raises does not bring the dispatch down", %{context: c, channel: ch} do
      defmodule RaisingExtra do
        def extra_content(_c, _ch), do: raise("boom")
      end

      assert AshDispatch.EventResolver.extra_content(RaisingExtra, c, ch) == %{}
    end
  end
end
