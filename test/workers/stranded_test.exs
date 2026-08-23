defmodule AshDispatch.Workers.StrandedTest do
  @moduledoc """
  The three fates of a receipt stuck in `:scheduled`.

  The edges are the whole point. Too eager and the sweep fights the normal
  path, racing a job that is about to run and risking a double send. Too lazy
  and receipts keep vanishing, which is the defect being fixed. Too willing
  to send and a customer receives an order confirmation from January.
  """
  use ExUnit.Case, async: true

  alias AshDispatch.Workers.Stranded

  @now ~U[2026-08-23 12:00:00Z]

  defp fate(seconds_ago, opts \\ []) do
    Stranded.action(DateTime.add(@now, -seconds_ago, :second), Keyword.put(opts, :now, @now))
  end

  describe "the grace period" do
    test "a receipt enqueued a moment ago is working, not stranded" do
      assert fate(5) == :leave
      assert fate(60) == :leave
    end

    test "just under the grace period is still left alone" do
      assert fate(30 * 60 - 1) == :leave
    end

    test "exactly at the grace period it counts as stranded" do
      # The boundary is stated rather than left to chance: a sweep that runs
      # every fifteen minutes will land on it eventually, and it should behave
      # the same each time.
      assert fate(30 * 60) == :rescue
    end
  end

  describe "rescue" do
    test "stranded but recent is handed to the existing retry machinery" do
      assert fate(2 * 3600) == :rescue
      assert fate(23 * 3600) == :rescue
    end

    test "just under the staleness ceiling is still worth sending" do
      assert fate(24 * 3600 - 1) == :rescue
    end
  end

  describe "close" do
    test "past the ceiling it is closed, never sent" do
      assert fate(24 * 3600) == :close
      assert fate(30 * 24 * 3600) == :close
    end

    test "the six-month case from production closes" do
      # The receipts that prompted this: February to July, all still sitting
      # in :scheduled in August.
      assert fate(180 * 24 * 3600) == :close
    end

    test "the reason says what happened and why it wasn't sent" do
      reason = Stranded.close_reason(DateTime.add(@now, -48 * 3600, :second), now: @now)

      assert reason =~ "48h"
      assert reason =~ "too old to send"
      refute reason =~ "nil"
    end
  end

  describe "the bounds are configurable" do
    test "an app that wants old mail delivered can raise the ceiling" do
      assert fate(48 * 3600, stale_after_hours: 24 * 30) == :rescue
    end

    test "an app with a slower queue can widen the grace period" do
      assert fate(45 * 60, stuck_after_minutes: 120) == :leave
    end

    test "the grace period wins over a ceiling set below it" do
      # A contradictory config (ceiling earlier than grace) resolves to
      # :leave, and that ordering is deliberate rather than incidental.
      #
      # Never touching a receipt that may still be in flight is the stronger
      # safety property: acting inside the grace window risks racing a job
      # that is about to run, and a double-sent mail cannot be taken back. A
      # misconfigured ceiling merely means the sweep does nothing, which is
      # the state the system was already in.
      assert fate(60 * 60, stuck_after_minutes: 120, stale_after_hours: 1) == :leave
    end
  end

  describe "timestamp shapes" do
    test "NaiveDateTime is accepted — Ash resources hand back naive UTC" do
      naive = ~N[2026-08-23 06:00:00]

      assert Stranded.action(naive, now: @now) == :rescue
    end

    test "a future timestamp is left alone rather than treated as ancient" do
      # Clock skew between app and database should never trigger a close.
      assert fate(-3600) == :leave
    end
  end
end
