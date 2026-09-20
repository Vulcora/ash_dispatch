defmodule AshDispatch.Workers.SendSMSTest do
  @moduledoc """
  Workern som gör själva SMS-sändningen.

  Den finns för att transporten tidigare anropade backenden synkront, inne i
  actionens transaktion. Det höll transaktionen öppen så länge leverantören
  dröjde, gjorde `time:`-schemaläggning oanvändbar, och lämnade kvittot utan
  väg tillbaka: `RetryFailedDeliveries` känner bara igen transporter som har
  en worker.
  """
  use ExUnit.Case, async: false

  alias AshDispatch.ReceiptStatus
  alias AshDispatch.Test.TransportReceipt
  alias AshDispatch.Workers.SendSMS

  defmodule LyckadBackend do
    @moduledoc false
    @behaviour AshDispatch.SMSBackend

    @impl true
    def deliver(receipt, context, channel, _event_config) do
      send(self(), {:anropad, context, channel})
      {:ok, ReceiptStatus.mark_sent(receipt, %{"id" => "s1"})}
    end
  end

  defmodule FallerandeBackend do
    @moduledoc false
    @behaviour AshDispatch.SMSBackend

    @impl true
    def deliver(receipt, _context, _channel, _event_config) do
      {:ok, ReceiptStatus.mark_failed(receipt, "leverantören svarade 500")}
    end
  end

  defmodule KrasandeBackend do
    @moduledoc false
    @behaviour AshDispatch.SMSBackend

    @impl true
    def deliver(_receipt, _context, _channel, _event_config) do
      raise "leverantörsklienten small"
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

  defp kvitto!(attrs \\ %{}) do
    TransportReceipt
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          event_id: "schedule.notified",
          audience: :user,
          transport: :sms,
          recipient: "+46701234567",
          content: %{message: "Körschema V39"}
        },
        attrs
      )
    )
    |> Ash.create!(authorize?: false)
  end

  defp kor(receipt), do: SendSMS.perform(%Oban.Job{args: %{"receipt_id" => receipt.id}})
  defp las(receipt), do: Ash.get!(TransportReceipt, receipt.id, authorize?: false)

  describe "riggen" do
    test "kön heter :sms" do
      assert SendSMS.__opts__()[:queue] == :sms
    end

    test "ett jobb per kvitto — 'skicka nu' ska inte kunna bli två SMS" do
      unique = SendSMS.__opts__()[:unique]
      assert unique[:keys] == [:receipt_id]
      assert :executing in unique[:states]
    end
  end

  describe "sändning" do
    test "lyckad sändning markerar :sent" do
      Application.put_env(:ash_dispatch, :sms_backend, LyckadBackend)
      r = kvitto!()

      assert :ok = kor(r)
      assert las(r).status == :sent
    end

    test "backenden får en kontext rekonstruerad ur kvittot" do
      # Jobbet bär bara kvitto-id:t, så den ursprungliga kontexten är borta.
      # Det som går att återskapa ska stämma.
      Application.put_env(:ash_dispatch, :sms_backend, LyckadBackend)
      kor(kvitto!())

      assert_received {:anropad, context, channel}
      assert context.event_id == "schedule.notified"
      assert context.data == %{}
      assert channel.transport == :sms
      assert channel.audience == :user
    end

    test "misslyckad sändning ger {:error, _} så Oban gör om" do
      Application.put_env(:ash_dispatch, :sms_backend, FallerandeBackend)
      r = kvitto!()

      assert {:error, _} = kor(r)
      assert las(r).status == :failed
    end

    test "en backend som kastar strandar inte kvittot i :sending" do
      # Utan rescue hade kvittot blivit kvar i :sending och först fångats av
      # Stranded-cronen, timmar senare.
      Application.put_env(:ash_dispatch, :sms_backend, KrasandeBackend)
      r = kvitto!()

      assert {:error, _} = kor(r)
      assert las(r).status == :failed
    end
  end

  describe "dubbletter och saknad konfiguration" do
    test "ett kvitto i terminalt läge skickas inte om" do
      Application.put_env(:ash_dispatch, :sms_backend, LyckadBackend)

      r =
        kvitto!()
        |> Ash.Changeset.for_update(:mark_sent, %{})
        |> Ash.update!(authorize?: false)

      assert :ok = kor(r)
      assert las(r).status == :sent
    end

    test "utan backend markeras kvittot :skipped, inte :failed" do
      Application.delete_env(:ash_dispatch, :sms_backend)
      r = kvitto!()

      assert :ok = kor(r)
      uppdaterat = las(r)
      assert uppdaterat.status == :skipped
      assert uppdaterat.error_message == "transport_not_implemented"
    end

    test "ett kvitto som inte finns är ett fel, inte en krasch" do
      Application.put_env(:ash_dispatch, :sms_backend, LyckadBackend)

      assert {:error, :receipt_not_found} =
               SendSMS.perform(%Oban.Job{
                 args: %{"receipt_id" => "00000000-0000-0000-0000-000000000000"}
               })
    end
  end
end
