defmodule AshDispatch.Transport.RetryTest do
  @moduledoc """
  The map of how a failed receipt is retried.

  The regression that gave the module its reason to exist: `:sms` was missing
  from both retry paths. A failed SMS receipt still went through `:retry` —
  which increments `retry_count` — and fell back to `:failed` when the enqueue
  failed. Five cron passes and 75 minutes later it read `:failed_permanent`,
  without having been resent even once. And `:retry`/`:reopen`/`:send_now` in
  admin refused it for the same reason, so there was no way back at all.
  """
  use ExUnit.Case, async: true

  alias AshDispatch.Transport.Retry

  describe "strategy/1" do
    test "email and sms enqueue a job" do
      assert {:worker, AshDispatch.Workers.SendEmail} = Retry.strategy(:email)
      assert {:worker, AshDispatch.Workers.SendSMS} = Retry.strategy(:sms)
    end

    test "in-app is retried inline, without a queue" do
      assert {:direct, AshDispatch.Transports.InApp} = Retry.strategy(:in_app)
    end

    test "transports with no way back say so" do
      for t <- [:discord, :slack, :webhook, :push] do
        assert Retry.strategy(t) == :unsupported, "#{t} should be :unsupported"
      end
    end

    test "an unknown transport is :unsupported, not a crash" do
      assert Retry.strategy(:carrier_pigeon) == :unsupported
    end
  end

  describe "retryable?/1" do
    test "sms can be retried" do
      assert Retry.retryable?(:sms)
    end

    test "the list holds only transports that keep receipts" do
      receipted = AshDispatch.Transport.Registry.receipted_atoms()

      for t <- Retry.retryable_transports() do
        assert t in receipted
      end

      assert :sms in Retry.retryable_transports()
      assert :email in Retry.retryable_transports()
      assert :in_app in Retry.retryable_transports()
    end
  end

  describe "the worker modules keep their contract" do
    test "every {:worker, _} exports new_for_receipt/1" do
      for t <- Retry.retryable_transports(),
          {:worker, module} <- [Retry.strategy(t)] do
        assert Code.ensure_loaded?(module)

        assert function_exported?(module, :new_for_receipt, 1),
               "#{inspect(module)} is missing new_for_receipt/1"
      end
    end

    test "every {:direct, _} exports retry_from_receipt/1" do
      for t <- Retry.retryable_transports(),
          {:direct, module} <- [Retry.strategy(t)] do
        assert Code.ensure_loaded?(module)

        assert function_exported?(module, :retry_from_receipt, 1),
               "#{inspect(module)} is missing retry_from_receipt/1"
      end
    end
  end
end
