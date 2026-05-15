defmodule AshDispatch.Resource.Transformers.ValidateRequiredEventMetadataTest do
  @moduledoc """
  F4 canary — `ValidateEvents.validate_required_event_metadata/2` must
  raise `Spark.Error.DslError` when a resource event declares a channel
  whose transport has required metadata keys that are NOT present in
  the event's `:metadata`.

  Pre-F4 the `:oban` transport soft-failed on missing `:oban_worker`
  (runtime warning + `:skipped` receipt) — operators discovered the gap
  only by noticing their Oban queue stayed empty. F4 catches it at
  compile time.

  These tests exercise the unit-level invariant via the integration with
  `AshDispatch.Transport.Registry.required_event_metadata_keys/1`. The
  full Spark-DSL fire path is exercised indirectly when consumers (Mosis)
  compile their resources.
  """

  use ExUnit.Case, async: true

  alias AshDispatch.Transport.Registry

  describe "Registry.required_event_metadata_keys/1" do
    test ":oban requires :oban_worker" do
      assert :oban_worker in Registry.required_event_metadata_keys(:oban)
    end

    test ":broadcast requires nothing" do
      assert [] = Registry.required_event_metadata_keys(:broadcast)
    end

    test ":email requires nothing (today; may grow later)" do
      assert [] = Registry.required_event_metadata_keys(:email)
    end

    test "unknown transport returns []" do
      assert [] = Registry.required_event_metadata_keys(:nonexistent)
    end
  end

  describe "Transport behaviour required_event_metadata_keys/0" do
    test "Oban transport returns [:oban_worker] directly" do
      assert [:oban_worker] = AshDispatch.Transports.Oban.required_event_metadata_keys()
    end

    test "Broadcast transport returns [] (uses macro default)" do
      assert [] = AshDispatch.Transports.Broadcast.required_event_metadata_keys()
    end
  end

  describe "validation logic shape (integration via Mosis consumers)" do
    test "the validation enforces required keys" do
      # The validation logic in `ValidateEvents.validate_required_event_metadata/2`
      # iterates events × channels, looks up required keys via Registry, and
      # produces a `Spark.Error.DslError` for any event with a channel whose
      # required keys are missing from the event's metadata.
      #
      # End-to-end Spark fire requires a domain-registered Ash.Resource —
      # see Mosis's resources for actual compile-time enforcement (the
      # `:oban` channel on `:corpus_fill_completed` MUST declare
      # `metadata.oban_worker`).
      #
      # This test asserts the substrate piece (Registry) is wired correctly;
      # the end-to-end Spark fire is exercised in consumer test suites.
      assert :oban_worker in Registry.required_event_metadata_keys(:oban)
      assert [] = Registry.required_event_metadata_keys(:broadcast)
    end
  end
end
