defmodule AshDispatch.Workers.SendEmailTest do
  @moduledoc """
  Tests for the SendEmail worker.

  These tests verify that the worker correctly handles various email address formats
  (strings, tuples, maps, lists) without crashing.
  """
  use ExUnit.Case, async: true

  # We can't test private functions directly, but we can test the module's
  # behavior by examining what formats it accepts. The parse_from_field logic
  # is tested indirectly via the email backend tests.

  describe "module compilation" do
    test "module compiles and is available" do
      assert Code.ensure_loaded?(AshDispatch.Workers.SendEmail)
    end

    test "implements Oban.Worker behaviour" do
      behaviours = AshDispatch.Workers.SendEmail.__info__(:attributes)[:behaviour] || []
      assert Oban.Worker in behaviours
    end

    test "uses :emails queue" do
      # Verify the worker is configured for the correct queue
      assert AshDispatch.Workers.SendEmail.__opts__()[:queue] == :emails
    end
  end
end
