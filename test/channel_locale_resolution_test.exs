defmodule AshDispatch.ChannelLocaleResolutionTest do
  @moduledoc """
  Unit tests for `AshDispatch.Dispatcher.resolve_channel_locale/3`.

  The priority chain (highest → lowest) must be:

  1. `channel.locale` (static override)
  2. `channel.locale_from` (dynamic on primary record)
  3. `recipient.locale` (NEW in 0.4.5)
  4. `context.locale` (event/resource-level fallback)
  """

  use ExUnit.Case, async: true

  alias AshDispatch.Channel
  alias AshDispatch.Context
  alias AshDispatch.Dispatcher

  defp ctx(opts \\ []) do
    %Context{
      event_id: "test",
      resource_key: :record,
      data: Keyword.get(opts, :data, %{}),
      variables: %{},
      locale: Keyword.get(opts, :locale, "en")
    }
  end

  describe "priority 1 — channel.locale (static override)" do
    test "wins over recipient.locale, channel.locale_from, and context.locale" do
      channel = %Channel{
        transport: :email,
        audience: :user,
        locale: "sv",
        locale_from: :record_locale
      }

      context = ctx(data: %{record: %{record_locale: "no"}}, locale: "fr")
      recipient = %{id: "u1", locale: "de"}

      assert Dispatcher.resolve_channel_locale(channel, context, recipient) == "sv"
    end
  end

  describe "priority 2 — channel.locale_from on primary record" do
    test "reads the configured field from context.data[resource_key]" do
      channel = %Channel{transport: :email, audience: :user, locale_from: :record_locale}
      context = ctx(data: %{record: %{record_locale: "no"}}, locale: "fr")

      assert Dispatcher.resolve_channel_locale(channel, context, nil) == "no"
    end

    test "wins over recipient.locale when present" do
      channel = %Channel{transport: :email, audience: :user, locale_from: :record_locale}
      context = ctx(data: %{record: %{record_locale: "no"}})
      recipient = %{id: "u1", locale: "de"}

      assert Dispatcher.resolve_channel_locale(channel, context, recipient) == "no"
    end

    test "falls through to recipient.locale when record field is nil" do
      channel = %Channel{transport: :email, audience: :user, locale_from: :record_locale}
      context = ctx(data: %{record: %{record_locale: nil}}, locale: "fr")
      recipient = %{id: "u1", locale: "de"}

      assert Dispatcher.resolve_channel_locale(channel, context, recipient) == "de"
    end

    test "falls through to context.locale when record field is nil and no recipient locale" do
      channel = %Channel{transport: :email, audience: :user, locale_from: :record_locale}
      context = ctx(data: %{record: %{record_locale: nil}}, locale: "fr")

      assert Dispatcher.resolve_channel_locale(channel, context, nil) == "fr"
    end
  end

  describe "priority 3 — recipient.locale (NEW in 0.4.5)" do
    test "wins over context.locale when no channel override and recipient has locale" do
      channel = %Channel{transport: :email, audience: :user}
      context = ctx(locale: "fr")
      recipient = %{id: "u1", locale: "sv"}

      assert Dispatcher.resolve_channel_locale(channel, context, recipient) == "sv"
    end

    test "empty-string recipient.locale is ignored (falls through to context)" do
      channel = %Channel{transport: :email, audience: :user}
      context = ctx(locale: "fr")
      recipient = %{id: "u1", locale: ""}

      assert Dispatcher.resolve_channel_locale(channel, context, recipient) == "fr"
    end

    test "nil recipient.locale is ignored" do
      channel = %Channel{transport: :email, audience: :user}
      context = ctx(locale: "fr")
      recipient = %{id: "u1", locale: nil}

      assert Dispatcher.resolve_channel_locale(channel, context, recipient) == "fr"
    end

    test "recipient without :locale key is treated as nil" do
      channel = %Channel{transport: :email, audience: :user}
      context = ctx(locale: "fr")
      recipient = %{id: "u1", email: "x@y.se"}

      assert Dispatcher.resolve_channel_locale(channel, context, recipient) == "fr"
    end

    test "non-binary recipient.locale (e.g. atom) is ignored" do
      channel = %Channel{transport: :email, audience: :user}
      context = ctx(locale: "fr")
      recipient = %{id: "u1", locale: :sv}

      assert Dispatcher.resolve_channel_locale(channel, context, recipient) == "fr"
    end

    test "fan-out: same channel, two recipients → two different locales" do
      channel = %Channel{transport: :email, audience: :user}
      context = ctx(locale: "en")

      seller = %{id: "s1", locale: "sv"}
      admin = %{id: "a1", locale: "en"}

      assert Dispatcher.resolve_channel_locale(channel, context, seller) == "sv"
      assert Dispatcher.resolve_channel_locale(channel, context, admin) == "en"
    end
  end

  describe "priority 4 — context.locale fallback" do
    test "used when no channel override, no recipient locale, no locale_from" do
      channel = %Channel{transport: :email, audience: :user}
      context = ctx(locale: "fr")

      assert Dispatcher.resolve_channel_locale(channel, context, nil) == "fr"
    end
  end

  describe "recipient struct support" do
    defmodule FakeUser do
      defstruct [:id, :email, :locale]
    end

    test "recipient as Ash-resource-shaped struct (with __struct__)" do
      channel = %Channel{transport: :email, audience: :user}
      context = ctx(locale: "en")
      recipient = %FakeUser{id: "u1", email: "x@y.se", locale: "sv"}

      assert Dispatcher.resolve_channel_locale(channel, context, recipient) == "sv"
    end
  end
end
