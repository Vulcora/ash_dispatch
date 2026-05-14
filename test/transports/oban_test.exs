defmodule AshDispatch.Transports.ObanTest do
  @moduledoc """
  Shape-level tests for the `:oban` transport. Oban itself isn't
  bootstrapped in the AshDispatch test suite (test env carries no
  Repo / no Oban supervision tree), so we exercise the metadata-
  reading + skip-on-missing-worker branches + atom-to-string args
  coercion without hitting `Oban.insert/1`. Integration coverage
  (real worker enqueue end-to-end) lives in the consuming app's
  test suite — Mosis ships such a canary for the
  `:corpus_fill_completed` → `PredictIncrementalOnFill` migration.
  """

  use ExUnit.Case, async: true

  alias AshDispatch.Transports.Oban, as: ObanTransport

  describe "module compilation + dispatcher registration" do
    test "module compiles and is available" do
      assert Code.ensure_loaded?(ObanTransport)
    end

    test "deliver/4 is exported" do
      Code.ensure_loaded!(ObanTransport)
      assert function_exported?(ObanTransport, :deliver, 4)
    end

    test "dispatcher's receipt-skip table includes :oban" do
      # `skip_receipt_for_transport?/1` is private; assert behaviour
      # via the public dispatch path's compiled shape — see
      # `lib/dispatcher.ex`. We do a textual check on the dispatcher
      # source to catch accidental regressions on the receipt-skip
      # list (both `:broadcast` and `:oban` must stay there).
      source = File.read!("lib/dispatcher.ex")
      assert source =~ "skip_receipt_for_transport?(:oban), do: true"
      assert source =~ "skip_receipt_for_transport?(:broadcast), do: true"
    end

    test "dispatcher's transport-routing case includes :oban" do
      source = File.read!("lib/dispatcher.ex")

      assert source =~ "Transports.Oban.deliver(receipt, context, channel, event_config)"
    end
  end

  describe "deliver/4 — missing oban_worker in metadata" do
    test "logs warning and returns {:ok, skipped} without crashing" do
      receipt = %{id: nil, status: :pending}
      context = %{event_id: "test_event", data: %{foo: 1}}
      channel = %{transport: :oban, audience: :system}
      # event_config carries no :oban_worker
      event_config = [metadata: []]

      assert {:ok, %{status: :skipped}} =
               ObanTransport.deliver(receipt, context, channel, event_config)
    end

    test "treats `nil` event_config[:metadata] as missing worker (soft skip)" do
      receipt = %{id: nil, status: :pending}
      context = %{event_id: "test_event", data: %{}}
      channel = %{transport: :oban, audience: :system}
      event_config = []

      assert {:ok, %{status: :skipped}} =
               ObanTransport.deliver(receipt, context, channel, event_config)
    end
  end

  describe "args coercion (private — exercised via deliver fail path)" do
    # `stringify_keys/1` is private. We can't call it directly, but
    # the skip-path doesn't touch it. The Mosis-side end-to-end test
    # asserts that the enqueued job's args have string keys; we trust
    # that integration here.

    test "module source coerces atom keys to strings" do
      source = File.read!("lib/transports/oban.ex")
      assert source =~ "{Atom.to_string(k), v}"
    end
  end
end
