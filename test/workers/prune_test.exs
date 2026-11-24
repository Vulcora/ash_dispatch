defmodule AshDispatch.Workers.PruneTest do
  @moduledoc """
  Retention, and that it is inert until a host asks for it.

  `ScrubSensitiveContent` covers the events a host marked
  `sensitive_content: true`. Everything else a receipt holds is kept forever,
  and a rendered letter is a letter: a name, an address, an order. BACKLOG 3
  said there was no retention or pruning at all, and three hosts wrote their
  own.

  The windows and the inertness are unit-testable without a database and are
  pinned here; `prune_postgres_test.exs` is the pass itself.
  """
  # Not async: reads :ash_dispatch config, which is global
  use ExUnit.Case, async: false

  alias AshDispatch.Workers.Prune

  @moduletag :capture_log

  @now ~U[2026-11-22 12:00:00Z]

  setup do
    keys = [
      :body_retention_hours,
      :receipt_retention_hours,
      :notification_retention_hours,
      :prune_batch_size
    ]

    saved = for key <- keys, do: {key, Application.fetch_env(:ash_dispatch, key)}
    for key <- keys, do: Application.delete_env(:ash_dispatch, key)

    on_exit(fn ->
      for {key, value} <- saved do
        case value do
          {:ok, old} -> Application.put_env(:ash_dispatch, key, old)
          :error -> Application.delete_env(:ash_dispatch, key)
        end
      end
    end)

    :ok
  end

  describe "windows/0" do
    test "all three are unset by default — the only safe default for a deleter" do
      assert Prune.windows() == %{body: nil, receipt: nil, notification: nil}
    end

    test "reads each one" do
      Application.put_env(:ash_dispatch, :body_retention_hours, 24)
      Application.put_env(:ash_dispatch, :receipt_retention_hours, 48)
      Application.put_env(:ash_dispatch, :notification_retention_hours, 72)

      assert Prune.windows() == %{body: 24, receipt: 48, notification: 72}
    end

    test "a window that is not a positive number of hours is ignored, loudly" do
      for junk <- [0, -5, "24", :forever, 1.5] do
        Application.put_env(:ash_dispatch, :body_retention_hours, junk)

        assert Prune.windows().body == nil, "#{inspect(junk)} was accepted as a window"
      end
    end
  end

  describe "cutoff/2" do
    test "an unset window has no cut-off, which is what makes it prune nothing" do
      assert Prune.cutoff(nil, @now) == nil
    end

    test "a window is that many hours back" do
      assert Prune.cutoff(24, @now) == ~U[2026-11-21 12:00:00Z]
      assert Prune.cutoff(24 * 90, @now) == ~U[2026-08-24 12:00:00Z]
    end
  end

  describe "receipt_cutoff/2" do
    test "no receipt window means no deletion, whatever the body window says" do
      assert Prune.receipt_cutoff(%{receipt: nil, body: 24}, @now) == nil
    end

    test "the receipt window alone" do
      assert Prune.receipt_cutoff(%{receipt: 48, body: nil}, @now) == ~U[2026-11-20 12:00:00Z]
    end

    test "the LATER of the two, so a short receipt window cannot outrun the body one" do
      # Deleting the row at 48h would take the audit trail the 90-day body
      # window was configured to keep.
      windows = %{receipt: 48, body: 24 * 90}

      assert Prune.receipt_cutoff(windows, @now) == Prune.cutoff(24 * 90, @now)
    end

    test "and the receipt window when it is the later one" do
      windows = %{receipt: 24 * 365, body: 24 * 90}

      assert Prune.receipt_cutoff(windows, @now) == Prune.cutoff(24 * 365, @now)
    end
  end

  describe "perform/1 with nothing configured" do
    test "is a no-op :ok — not a query, not a log line a night" do
      assert :ok = Prune.perform(%Oban.Job{args: %{}})
    end
  end

  describe "the marker" do
    test "is its own, so an emptied body is tellable from a scrubbed one" do
      assert Prune.marker() != AshDispatch.Workers.ScrubSensitiveContent.marker()
      assert Prune.marker() =~ "retention"
    end
  end

  describe "the queue" do
    test "runs in :default, like the other cron workers" do
      assert Keyword.fetch!(Prune.__opts__(), :queue) == :default
    end
  end
end
