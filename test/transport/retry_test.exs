defmodule AshDispatch.Transport.RetryTest do
  @moduledoc """
  Kartan över hur ett misslyckat kvitto görs om.

  Regressionen som gav modulen dess existens: `:sms` saknades i båda
  retry-vägarna. Ett misslyckat SMS-kvitto gick ändå igenom `:retry` — vilket
  räknar upp `retry_count` — och föll tillbaka till `:failed` när köandet
  misslyckades. Fem cronvarv och 75 minuter senare stod det
  `:failed_permanent`, utan att ha skickats om en enda gång. Och
  `:retry`/`:reopen`/`:send_now` i admin avvisade det av samma skäl, så det
  fanns ingen väg tillbaka alls.
  """
  use ExUnit.Case, async: true

  alias AshDispatch.Transport.Retry

  describe "strategy/1" do
    test "e-post och sms köar ett jobb" do
      assert {:worker, AshDispatch.Workers.SendEmail} = Retry.strategy(:email)
      assert {:worker, AshDispatch.Workers.SendSMS} = Retry.strategy(:sms)
    end

    test "in-app görs om direkt, utan kö" do
      assert {:direct, AshDispatch.Transports.InApp} = Retry.strategy(:in_app)
    end

    test "transporter utan väg tillbaka säger det" do
      for t <- [:discord, :slack, :webhook, :push] do
        assert Retry.strategy(t) == :unsupported, "#{t} borde vara :unsupported"
      end
    end

    test "en okänd transport är :unsupported, inte en krasch" do
      assert Retry.strategy(:duvpost) == :unsupported
    end
  end

  describe "retryable?/1" do
    test "sms går att göra om" do
      assert Retry.retryable?(:sms)
    end

    test "listan innehåller bara kvitterade transporter" do
      kvitterade = AshDispatch.Transport.Registry.receipted_atoms()

      for t <- Retry.retryable_transports() do
        assert t in kvitterade
      end

      assert :sms in Retry.retryable_transports()
      assert :email in Retry.retryable_transports()
      assert :in_app in Retry.retryable_transports()
    end
  end

  describe "workermodulerna håller sitt kontrakt" do
    test "varje {:worker, _} har new_for_receipt/1" do
      for t <- Retry.retryable_transports(),
          {:worker, modul} <- [Retry.strategy(t)] do
        assert Code.ensure_loaded?(modul)

        assert function_exported?(modul, :new_for_receipt, 1),
               "#{inspect(modul)} saknar new_for_receipt/1"
      end
    end

    test "varje {:direct, _} har retry_from_receipt/1" do
      for t <- Retry.retryable_transports(),
          {:direct, modul} <- [Retry.strategy(t)] do
        assert Code.ensure_loaded?(modul)

        assert function_exported?(modul, :retry_from_receipt, 1),
               "#{inspect(modul)} saknar retry_from_receipt/1"
      end
    end
  end
end
