defmodule AshDispatch.DispatcherContentTest do
  @moduledoc """
  The key the dispatcher WRITES must be the key the transport READS.

  ## The bug this test exists for

  `build_inline_content/4` wrote the body under `:message` for every
  transport. `AshDispatch.Transports.Slack` builds its `"text"` from
  `get_content(content, :notification_message)` and
  `AshDispatch.Transports.Discord` its `"content"` from the same key — the
  structure both moduledocs document as "Expected content structure". So a
  declared `content: [notification_message: ...]` on a `transport: :slack`
  channel reached the receipt and never reached the payload: Slack and Discord
  were posted a payload whose only required field was `nil`.

  `build_module_content/5` had the same mismatch from the other side.
  `:slack` and `:discord` fell through to the catch-all — `%{message:
  notification_message(...)}` — so the module callback's text did not arrive
  either. Both halves are needed, which is why the hybrid case below asserts
  the PAYLOAD and not just the content map.

  ## Why the assertion goes through `job_args/3`

  `build_slack_payload/2` is private; `job_args/3` is public precisely so the
  shape that lands in `oban_jobs.args` can be read without an Oban instance
  (see `test/transports/webhook_url_env_test.exs`). Asserting on
  `attrs.content` alone would have gone green all along — the content map was
  never the broken half.

  `test/transports/inline_content_text_test.exs` guards the same class of bug
  structurally, by reading the source. It could not see this one: it asks
  whether a branch READS the body from the DSL, and both branches did.
  """

  # Async disabled: the hybrid case registers an event module in application
  # config, which is global.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias AshDispatch.Channel
  alias AshDispatch.Context
  alias AshDispatch.Dispatcher
  alias AshDispatch.Transports.Discord
  alias AshDispatch.Transports.Slack

  # A fake host. The path of a Slack or Discord webhook URL is the credential,
  # so no test may carry a real one.
  @url "https://hooks.slack.test/services/T000/B000/not-a-real-token"

  # The event id the hybrid case registers `TextFromTheModule` under.
  @hybrid_event "dispatcher_content_test.hybrid"

  defmodule TextFromTheModule do
    @moduledoc """
    An event module that contributes nothing but its body, which is all the
    hybrid case is about.
    """
    def notification_message(_context, _channel), do: "the module's own text"
  end

  # What the two transports read, and from which key.
  @transports [
    {:slack, Slack, "text"},
    {:discord, Discord, "content"}
  ]

  describe "the body declared in the channel's content" do
    for {transport, module, key} <- @transports do
      test "#{transport}: the payload's \"#{key}\" is the interpolated message" do
        channel =
          channel(unquote(transport), content: %{notification_message: "Order {{number}} is out"})

        context = context(%{number: "1007"})

        assert payload(unquote(module), channel, context)[unquote(key)] ==
                 "Order 1007 is out"
      end

      test "#{transport}: content: [message: ...] is read the same way" do
        # Both spellings have always been accepted by the branch; what was
        # missing was the key it wrote them to.
        channel = channel(unquote(transport), content: %{message: "Ticket {{id}} was closed"})
        context = context(%{id: "42"})

        assert payload(unquote(module), channel, context)[unquote(key)] ==
                 "Ticket 42 was closed"
      end

      test "#{transport}: the receipt's content carries the key the transport reads" do
        channel = channel(unquote(transport), content: %{notification_message: "Hello"})

        assert content(channel, context())[:notification_message] == "Hello"
      end
    end
  end

  describe "hybrid mode: a module's body and a channel that declares none" do
    setup do
      previous_modules = Application.fetch_env(:ash_dispatch, :event_modules)
      previous_otp_app = Application.fetch_env(:ash_dispatch, :otp_app)

      # `EventRegistry.get_event_modules/0` falls back on `:event_modules`
      # only when no `:otp_app` is configured.
      Application.delete_env(:ash_dispatch, :otp_app)

      Application.put_env(:ash_dispatch, :event_modules, [{@hybrid_event, TextFromTheModule}])

      on_exit(fn ->
        restore(:event_modules, previous_modules)
        restore(:otp_app, previous_otp_app)
      end)

      :ok
    end

    for {transport, module, key} <- @transports do
      test "#{transport}: the callback's text survives a channel with no body" do
        # The channel HAS inline content — an icon, not a body — so the inline
        # branch runs and its result is merged over the module's. That is the
        # case `maybe_put/3` exists for: `interpolate(nil, _)` is `nil`, and a
        # literal key would write that nil over the callback's text.
        channel = channel(unquote(transport), content: %{slack_icon_emoji: ":tada:"})
        context = context(%{}, @hybrid_event)

        assert payload(unquote(module), channel, context)[unquote(key)] ==
                 "the module's own text"
      end

      test "#{transport}: a channel that declares a body still wins over the callback" do
        channel = channel(unquote(transport), content: %{notification_message: "the DSL's text"})
        context = context(%{}, @hybrid_event)

        assert payload(unquote(module), channel, context)[unquote(key)] == "the DSL's text"
      end
    end
  end

  # ── Helpers ──────────────────────────────────────────────────

  defp channel(transport, opts) do
    %Channel{
      transport: transport,
      audience: :team,
      webhook_url: @url,
      content: Keyword.fetch!(opts, :content)
    }
  end

  defp context(variables \\ %{}, event_id \\ "dispatcher_content_test.inline") do
    %Context{event_id: event_id, data: %{}, variables: variables, metadata: %{}}
  end

  # The content map the receipt would have stored, built by the same seam
  # `AshDispatch.Preview` renders through. The status is `:unreachable` here —
  # this case configures no `recipient_fields` for Slack or Discord — and the
  # content is rendered either way, which is what is under test.
  defp content(channel, context) do
    {_status, attrs} =
      Dispatcher.build_receipt(context, channel, %{}, %{id: Ecto.UUID.generate()})

    attrs.content
  end

  defp payload(module, channel, context) do
    receipt = %{id: Ecto.UUID.generate(), content: content(channel, context)}
    assert {:ok, args} = module.job_args(receipt, context, channel)
    args["payload"]
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:ash_dispatch, key, value)
  defp restore(key, :error), do: Application.delete_env(:ash_dispatch, key)
end
