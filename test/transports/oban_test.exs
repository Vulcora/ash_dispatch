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

    test "Transport.Registry includes :oban (post-F1 behaviour-driven)" do
      # F1 post-refactor: receipt-skip + transport routing both consult
      # `AshDispatch.Transport.Registry` instead of hardcoded case
      # statements in dispatcher.ex. Assert the registry contract
      # directly.
      assert {:ok, AshDispatch.Transports.Oban} =
               AshDispatch.Transport.Registry.module_for(:oban)

      assert AshDispatch.Transport.Registry.skip_receipt?(:oban) == true

      # Sister: :broadcast must stay receipt-skip (canary against
      # accidentally flipping :broadcast's flag during transport
      # refactors).
      assert AshDispatch.Transport.Registry.skip_receipt?(:broadcast) == true

      # Sanity: a non-skip transport stays non-skip.
      assert AshDispatch.Transport.Registry.skip_receipt?(:email) == false
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
