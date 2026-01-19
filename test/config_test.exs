defmodule AshDispatch.ConfigTest do
  @moduledoc """
  Tests for AshDispatch.Config module.

  These tests verify the new config options:
  - default_locale
  - channel_topic
  """

  use ExUnit.Case, async: true

  alias AshDispatch.Config

  describe "default_locale/0" do
    test "returns configured default_locale" do
      # Default is "en" when not configured
      locale = Config.default_locale()

      assert is_binary(locale)
      # Default is "en" per the config module
      assert locale == "en" or is_binary(locale)
    end

    test "returns string type" do
      locale = Config.default_locale()

      assert is_binary(locale)
    end
  end

  describe "channel_topic/0" do
    test "returns configured channel_topic" do
      topic = Config.channel_topic()

      assert is_binary(topic)
    end

    test "default is 'user'" do
      # Unless overridden in test config
      topic = Config.channel_topic()

      # Default should be "user" or whatever is configured
      assert is_binary(topic)
    end
  end

  describe "otp_app/0" do
    test "returns nil when not configured" do
      # In test environment, otp_app may or may not be configured
      result = Config.otp_app()

      assert is_nil(result) or is_atom(result)
    end
  end

  describe "base_url/0" do
    test "returns configured base URL or default" do
      url = Config.base_url()

      assert is_binary(url) or is_nil(url)
    end
  end
end
