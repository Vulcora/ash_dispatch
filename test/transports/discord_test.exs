defmodule AshDispatch.Transports.DiscordMentionsTest do
  @moduledoc """
  A Discord message body is not escaped, which is deliberate — but mentions
  are the one case where that is not merely cosmetic. Discord parses every
  mention in the text by default, so an `@everyone` in a company name pings a
  whole server.
  """
  use ExUnit.Case, async: true

  alias AshDispatch.Transports.Discord

  describe "allowed_mentions" do
    test "is off by default, so a body cannot ping a server" do
      args = payload(%{notification_message: "Welcome, @everyone Ltd"})

      assert args["allowed_mentions"] == %{"parse" => []}
      # The body itself is sent as written.
      assert args["content"] == "Welcome, @everyone Ltd"
    end

    test "an event that genuinely wants to ping says so" do
      args =
        payload(%{
          notification_message: "Deploy done",
          discord_allowed_mentions: %{"parse" => ["users"]}
        })

      assert args["allowed_mentions"] == %{"parse" => ["users"]}
    end

    test "even the non-map fallback carries it" do
      assert payload("not a map")["allowed_mentions"] == %{"parse" => []}
    end
  end

  defp payload(content) do
    Discord.build_payload(content, %{})
  end
end
