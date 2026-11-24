defmodule AshDispatch.Transports.DiscordMentionsTest do
  @moduledoc """
  A Discord message body is not escaped, which is deliberate — but mentions
  are the one case where that is not merely cosmetic. Discord parses every
  mention in the text by default, so an `@everyone` in a company name pings a
  whole server.
  """
  use ExUnit.Case, async: false

  alias AshDispatch.Transports.Discord

  describe "allowed_mentions is sent only when somebody asked" do
    test "nothing by default — which is byte-for-byte what rc.5 sent" do
      # A default that suppressed mentions would silence a host that
      # deliberately pings a channel from an event body, with no way for it to
      # know why. A patch may not do that.
      args = payload(%{notification_message: "Welcome, @everyone Ltd"})

      refute Map.has_key?(args, "allowed_mentions")
      # The body itself is sent as written.
      assert args["content"] == "Welcome, @everyone Ltd"
    end

    test "the config key suppresses them everywhere" do
      put_env(:discord_suppress_mentions, true)

      assert payload(%{notification_message: "@everyone Ltd"})["allowed_mentions"] ==
               %{"parse" => []}
    end

    test "and the channel's own content suppresses them for one channel" do
      args =
        payload(%{notification_message: "@everyone Ltd", discord_suppress_mentions: true})

      assert args["allowed_mentions"] == %{"parse" => []}
    end

    test "an explicit value wins over either suppression" do
      put_env(:discord_suppress_mentions, true)

      args =
        payload(%{
          notification_message: "Deploy done",
          discord_allowed_mentions: %{"parse" => ["users"]}
        })

      assert args["allowed_mentions"] == %{"parse" => ["users"]}
    end

    test "the non-map fallback carries none either" do
      refute Map.has_key?(payload("not a map"), "allowed_mentions")
    end
  end

  describe "the inline DSL can reach the options" do
    test "a channel's declared suppression reaches the payload" do
      # `build_inline_content/4`'s `:discord` branch copied only the body and
      # the URL, so both mention options were accepted in the DSL and silently
      # dropped on the way out.
      channel = %AshDispatch.Channel{
        transport: :discord,
        audience: :team,
        webhook_url: "https://discord.test/hook",
        content: %{discord_suppress_mentions: true, message: "@everyone Ltd"}
      }

      context = %AshDispatch.Context{
        event_id: "x.y",
        data: %{},
        variables: %{},
        metadata: %{}
      }

      {_status, attrs} = AshDispatch.Dispatcher.build_receipt(context, channel, %{}, nil)

      assert payload(attrs.content)["allowed_mentions"] == %{"parse" => []}
    end

    test "and a declared explicit value too" do
      channel = %AshDispatch.Channel{
        transport: :discord,
        audience: :team,
        webhook_url: "https://discord.test/hook",
        content: %{discord_allowed_mentions: %{"parse" => ["roles"]}, message: "hi"}
      }

      context = %AshDispatch.Context{
        event_id: "x.y",
        data: %{},
        variables: %{},
        metadata: %{}
      }

      {_status, attrs} = AshDispatch.Dispatcher.build_receipt(context, channel, %{}, nil)

      assert payload(attrs.content)["allowed_mentions"] == %{"parse" => ["roles"]}
    end
  end

  defp put_env(key, value) do
    previous = Application.fetch_env(:ash_dispatch, key)
    Application.put_env(:ash_dispatch, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:ash_dispatch, key, old)
        :error -> Application.delete_env(:ash_dispatch, key)
      end
    end)
  end

  defp payload(content) do
    Discord.build_payload(content, %{})
  end
end
