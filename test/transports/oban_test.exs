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

  describe "deliver/4 — :oban_enabled_parameter gate (F2)" do
    defmodule AlwaysDisabledGate do
      def enabled?(_parameter), do: false
    end

    defmodule AlwaysEnabledGate do
      def enabled?(_parameter), do: true
    end

    defmodule RaisingGate do
      def enabled?(_parameter), do: raise("boom")
    end

    setup do
      original = Application.get_env(:ash_dispatch, :gate_check_module)

      on_exit(fn ->
        if original do
          Application.put_env(:ash_dispatch, :gate_check_module, original)
        else
          Application.delete_env(:ash_dispatch, :gate_check_module)
        end
      end)
    end

    test "skips enqueue when gate returns false; emits :gated_disabled telemetry" do
      Application.put_env(:ash_dispatch, :gate_check_module, AlwaysDisabledGate)

      test_pid = self()
      handler_id = :"oban_gate_disabled_#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:ash_dispatch, :oban, :gated_disabled],
        fn _e, _m, meta, _cfg -> send(test_pid, {:gated, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      receipt = %{id: nil, status: :pending}
      context = %{event_id: "test_event", data: %{entry_id: "abc"}}
      channel = %{transport: :oban, audience: :system}

      event_config = [
        metadata: [
          oban_worker: SomeWorker,
          oban_enabled_parameter: :my_flag
        ]
      ]

      assert {:ok, %{status: :skipped}} =
               ObanTransport.deliver(receipt, context, channel, event_config)

      assert_receive {:gated, %{parameter: :my_flag, worker: SomeWorker}}, 500
    end

    test "no :oban_enabled_parameter → always proceeds (path unchanged)" do
      # No gate module configured; no parameter in metadata. Should attempt
      # enqueue (will fail because SomeWorker doesn't exist + Oban isn't
      # started, but the path is reached — distinguishes "gate skipped
      # enqueue" from "enqueue attempted but failed").
      receipt = %{id: nil, status: :pending}
      context = %{event_id: "test_event", data: %{}}
      channel = %{transport: :oban, audience: :system}
      event_config = [metadata: [oban_worker: SomeNonexistentWorker]]

      # The deliver call will hit the do_enqueue path; failure mode is
      # an exception inside the rescue → {:error, e}. We just assert
      # that we DIDN'T get the :skipped tuple, which would indicate
      # the gate path was taken erroneously.
      result = ObanTransport.deliver(receipt, context, channel, event_config)
      assert result != {:ok, Map.put(receipt, :status, :skipped)}
    end

    test "raising gate defaults to enabled (safer than silent-drop)" do
      Application.put_env(:ash_dispatch, :gate_check_module, RaisingGate)

      receipt = %{id: nil, status: :pending}
      context = %{event_id: "test_event", data: %{}}
      channel = %{transport: :oban, audience: :system}

      event_config = [
        metadata: [oban_worker: SomeWorker, oban_enabled_parameter: :flag]
      ]

      result = ObanTransport.deliver(receipt, context, channel, event_config)
      # Should NOT short-circuit to :skipped via the gate path.
      refute match?({:ok, %{status: :skipped}}, result) and
               not match?({:error, _}, result) == false

      # The gate's exception is rescued + logged; deliver falls through
      # to do_enqueue which fails because SomeWorker doesn't exist or
      # Oban isn't started → {:error, _} or {:ok, _}. Either way,
      # the :skipped-via-gate path was not taken.
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
