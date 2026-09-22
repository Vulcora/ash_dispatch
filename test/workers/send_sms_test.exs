defmodule AshDispatch.Workers.SendSMSTest do
  @moduledoc """
  The worker that does the actual sending.

  It exists because the transport used to call the backend synchronously,
  inside the action's transaction. That held the transaction open for as long
  as the provider took, made `time:` scheduling unusable, and left the receipt
  with no way back: `RetryFailedDeliveries` only recognises transports that
  have a worker.
  """
  use ExUnit.Case, async: false

  alias AshDispatch.ReceiptStatus
  alias AshDispatch.Test.TransportReceipt
  alias AshDispatch.Workers.SendSMS

  defmodule SucceedingBackend do
    @moduledoc false
    @behaviour AshDispatch.SMSBackend

    @impl true
    def deliver(receipt, context, channel, _event_config) do
      send(self(), {:called, context, channel})
      {:ok, ReceiptStatus.mark_sent(receipt, %{"id" => "s1"})}
    end
  end

  defmodule FailingBackend do
    @moduledoc false
    @behaviour AshDispatch.SMSBackend

    @impl true
    def deliver(receipt, _context, _channel, _event_config) do
      {:ok, ReceiptStatus.mark_failed(receipt, "provider answered 500")}
    end
  end

  defmodule RaisingBackend do
    @moduledoc false
    @behaviour AshDispatch.SMSBackend

    @impl true
    def deliver(_receipt, _context, _channel, _event_config) do
      raise "provider client blew up"
    end
  end

  setup do
    Application.put_env(:ash_dispatch, :delivery_receipt_resource, TransportReceipt)

    on_exit(fn ->
      Application.delete_env(:ash_dispatch, :delivery_receipt_resource)
      Application.delete_env(:ash_dispatch, :sms_backend)
    end)

    :ok
  end

  defp receipt!(attrs \\ %{}) do
    TransportReceipt
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          event_id: "orders.shipped",
          audience: :user,
          transport: :sms,
          recipient: "+46701234567",
          content: %{message: "Your order is on its way"}
        },
        attrs
      )
    )
    |> Ash.create!(authorize?: false)
  end

  defp run(receipt), do: SendSMS.perform(%Oban.Job{args: %{"receipt_id" => receipt.id}})
  defp reload(receipt), do: Ash.get!(TransportReceipt, receipt.id, authorize?: false)

  describe "the rig" do
    test "the queue is named :sms" do
      assert SendSMS.__opts__()[:queue] == :sms
    end

    test "one job per receipt — a 'send now' must not become two messages" do
      unique = SendSMS.__opts__()[:unique]
      assert unique[:keys] == [:receipt_id]
      assert :executing in unique[:states]
    end
  end

  describe "sending" do
    test "a successful send marks :sent" do
      Application.put_env(:ash_dispatch, :sms_backend, SucceedingBackend)
      r = receipt!()

      assert :ok = run(r)
      assert reload(r).status == :sent
    end

    test "the backend gets a context reconstructed from the receipt" do
      # The job carries only the receipt id, so the original context is gone.
      # What can be rebuilt has to be right.
      Application.put_env(:ash_dispatch, :sms_backend, SucceedingBackend)
      run(receipt!())

      assert_received {:called, context, channel}
      assert context.event_id == "orders.shipped"
      assert context.data == %{}
      assert channel.transport == :sms
      assert channel.audience == :user
    end

    test "a failed send returns {:error, _} so Oban retries" do
      Application.put_env(:ash_dispatch, :sms_backend, FailingBackend)
      r = receipt!()

      assert {:error, _} = run(r)
      assert reload(r).status == :failed
    end

    test "a backend that raises does not strand the receipt in :sending" do
      # Without the rescue the receipt would sit in :sending until the
      # stranded-receipt cron found it, hours later.
      Application.put_env(:ash_dispatch, :sms_backend, RaisingBackend)
      r = receipt!()

      assert {:error, _} = run(r)
      assert reload(r).status == :failed
    end
  end

  describe "duplicates and missing configuration" do
    test "a receipt in a terminal state is not sent again" do
      Application.put_env(:ash_dispatch, :sms_backend, SucceedingBackend)

      r =
        receipt!()
        |> Ash.Changeset.for_update(:mark_sent, %{})
        |> Ash.update!(authorize?: false)

      assert :ok = run(r)
      assert reload(r).status == :sent
    end

    test "with no backend the receipt is marked :skipped, not :failed" do
      Application.delete_env(:ash_dispatch, :sms_backend)
      r = receipt!()

      assert :ok = run(r)
      updated = reload(r)
      assert updated.status == :skipped
      assert updated.error_message == "transport_not_implemented"
    end

    test "a receipt that does not exist is an error, not a crash" do
      Application.put_env(:ash_dispatch, :sms_backend, SucceedingBackend)

      assert {:error, :receipt_not_found} =
               SendSMS.perform(%Oban.Job{
                 args: %{"receipt_id" => "00000000-0000-0000-0000-000000000000"}
               })
    end
  end
end
