defmodule AshDispatch.ReceiptsTest do
  @moduledoc """
  A receipt for something the library did not send.

  Every installation has a send outside the dispatcher, and a missing receipt
  is not a neutral gap: it reads as "nothing was sent". One installation
  measured ninety-two of ninety-six cases where a recipient had been reached
  and no letter existed to prove it.
  """
  # Not async: configures :ash_dispatch, which is global
  use ExUnit.Case, async: false

  alias AshDispatch.Reason
  alias AshDispatch.Receipts
  alias AshDispatch.Test.StrictReceipt

  @moduletag :capture_log

  setup do
    previous = Application.fetch_env(:ash_dispatch, :delivery_receipt_resource)
    Application.put_env(:ash_dispatch, :delivery_receipt_resource, StrictReceipt)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:ash_dispatch, :delivery_receipt_resource, old)
        :error -> Application.delete_env(:ash_dispatch, :delivery_receipt_resource)
      end
    end)

    :ok
  end

  @attrs %{
    event_id: "bookings.reminder",
    transport: :sms,
    audience: :user,
    recipient: "+46701234567",
    content: %{"message" => "Your booking is tomorrow"}
  }

  describe "{:sent, response}" do
    test "records a sent receipt with the provider's id" do
      assert {:ok, receipt} = Receipts.record(@attrs, {:sent, %{id: "prov-123", ok: true}})

      assert receipt.status == :sent
      assert receipt.provider_id == "prov-123"
      assert receipt.provider_response == %{id: "prov-123", ok: true}
      assert receipt.event_id == "bookings.reminder"
      assert receipt.transport == :sms
      assert receipt.recipient == "+46701234567"
    end

    test "takes a string id too — a provider's JSON has one" do
      assert {:ok, receipt} = Receipts.record(@attrs, {:sent, %{"id" => "prov-9"}})

      assert receipt.provider_id == "prov-9"
    end

    test "a response with no id is still a send" do
      assert {:ok, receipt} = Receipts.record(@attrs, {:sent, %{}})

      assert receipt.status == :sent
      assert receipt.provider_id == nil
    end

    test "and so is a response that is not a map" do
      assert {:ok, receipt} = Receipts.record(@attrs, {:sent, :ok})

      assert receipt.status == :sent
    end
  end

  describe "{:skipped, reason}" do
    test "records a skipped receipt with the reason" do
      assert {:ok, receipt} = Receipts.record(@attrs, {:skipped, "on our own blocklist"})

      assert receipt.status == :skipped
      assert receipt.error_message == "on our own blocklist"
      # Not one of the library's own reasons, so :other rather than a guess.
      assert Reason.of(receipt) == :other
    end

    test "takes :skip as well as :skipped" do
      assert {:ok, receipt} = Receipts.record(@attrs, {:skip, "quiet hours"})

      assert receipt.status == :skipped
    end

    test "a library reason is classified as itself" do
      assert {:ok, receipt} =
               Receipts.record(@attrs, {:skipped, AshDispatch.DeliveryMode.reason(:dry_run)})

      assert Reason.of(receipt) == :delivery_dry_run
    end
  end

  describe "{:error, reason}" do
    test "records failed_permanent, so the retry sweep does not take it over" do
      # A `:failed` receipt is what RetryFailedDeliveries picks up, and it
      # would enqueue a send of OUR rendering for a letter we never composed.
      assert {:ok, receipt} = Receipts.record(@attrs, {:error, :provider_timeout})

      assert receipt.status == :failed_permanent
      assert receipt.error_message == ":provider_timeout"
    end

    test "retry?: true hands it to the library on purpose" do
      assert {:ok, receipt} = Receipts.record(@attrs, {:error, "502"}, retry?: true)

      assert receipt.status == :failed
    end

    test "a string reason is kept as written" do
      assert {:ok, receipt} = Receipts.record(@attrs, {:error, "550 mailbox full"})

      assert receipt.error_message == "550 mailbox full"
    end
  end

  describe "what it never does" do
    test "nothing is delivered and no job is enqueued" do
      # The configured receipt resource is ETS and there is no Oban running in
      # this test, so a job enqueued here would raise rather than pass.
      assert {:ok, _} = Receipts.record(@attrs, {:sent, %{id: "x"}})
    end

    test "an unknown outcome leaves the receipt alone and says so" do
      assert {:error, {:unknown_outcome, :maybe}} = Receipts.record(@attrs, :maybe)
    end
  end

  describe "the attributes" do
    test "a key the receipt resource does not accept is dropped, not raised on" do
      assert {:ok, receipt} =
               Receipts.record(
                 Map.put(@attrs, :invented_by_a_host, "whatever"),
                 {:sent, %{id: "x"}}
               )

      assert receipt.status == :sent
    end

    test "source_type and source_id are carried, which is what a history groups by" do
      assert {:ok, receipt} =
               Receipts.record(
                 Map.merge(@attrs, %{source_type: "Booking", source_id: "b-1"}),
                 {:sent, %{id: "x"}}
               )

      assert receipt.source_type == "Booking"
      assert receipt.source_id == "b-1"
    end
  end

  describe "with no receipt resource configured" do
    setup do
      Application.delete_env(:ash_dispatch, :delivery_receipt_resource)
      :ok
    end

    test "it says so rather than pretending to have recorded something" do
      assert {:error, :no_delivery_receipt_resource} =
               Receipts.record(@attrs, {:sent, %{id: "x"}})
    end
  end
end
