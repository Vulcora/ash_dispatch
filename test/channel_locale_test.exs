defmodule AshDispatch.ChannelLocaleTest do
  @moduledoc """
  Tests for locale fields in AshDispatch.Channel struct.

  Verifies the new locale-related fields:
  - locale: Static locale for the channel
  - locale_from: Dynamic locale field to read from record
  - locales: List of locales for template generation
  """

  use ExUnit.Case, async: true

  alias AshDispatch.Channel

  describe "Channel struct locale fields" do
    test "creates channel with static locale" do
      channel = %Channel{
        transport: :email,
        audience: :customer,
        locale: "sv"
      }

      assert channel.locale == "sv"
      assert channel.locale_from == nil
      assert channel.locales == []
    end

    test "creates channel with dynamic locale_from" do
      channel = %Channel{
        transport: :email,
        audience: :customer,
        locale_from: :visitor_locale
      }

      assert channel.locale == nil
      assert channel.locale_from == :visitor_locale
    end

    test "creates channel with locales list for template generation" do
      channel = %Channel{
        transport: :email,
        audience: :customer,
        locales: ["sv", "en", "no"]
      }

      assert channel.locales == ["sv", "en", "no"]
    end

    test "locale and locale_from can coexist (locale takes priority at runtime)" do
      channel = %Channel{
        transport: :email,
        audience: :customer,
        locale: "sv",
        locale_from: :visitor_locale
      }

      assert channel.locale == "sv"
      assert channel.locale_from == :visitor_locale
    end

    test "default values for locale fields" do
      channel = %Channel{
        transport: :email,
        audience: :customer
      }

      assert channel.locale == nil
      assert channel.locale_from == nil
      assert channel.locales == []
    end
  end

  describe "Channel struct other defaults" do
    test "time defaults to immediate" do
      channel = %Channel{transport: :email, audience: :customer}

      assert channel.time == {:in, 0}
    end

    test "policy defaults to always" do
      channel = %Channel{transport: :email, audience: :customer}

      assert channel.policy == :always
    end

    test "optional defaults to false" do
      channel = %Channel{transport: :email, audience: :customer}

      assert channel.optional == false
    end

    test "exclude_actor defaults to false" do
      channel = %Channel{transport: :email, audience: :customer}

      assert channel.exclude_actor == false
    end
  end
end
