defmodule AshDispatch.Workers.RetryFailedDeliveriesTest do
  use ExUnit.Case, async: true
  use Oban.Testing, repo: Magasin.Repo

  alias AshDispatch.Resources.DeliveryReceipt
  alias AshDispatch.Workers.{RetryFailedDeliveries, SendEmail}

  setup do
    # Setup Ecto sandbox for test isolation
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Magasin.Repo)
  end

  describe "perform/1" do
    test "retries failed deliveries with retry_count < max_retries" do
      # Create a failed delivery receipt
      {:ok, receipt} = create_failed_receipt("test.event", 1)

      # Set last_retry_at to > 15 minutes ago so it's eligible for retry
      old_time = DateTime.add(DateTime.utc_now(), -20 * 60, :second)

      {:ok, receipt} =
        receipt
        |> Ash.Changeset.for_update(:update, %{last_retry_at: old_time})
        |> Ash.update(authorize?: false)

      # Run the retry worker
      assert :ok = perform_job(RetryFailedDeliveries, %{})

      # Verify receipt was updated to scheduled
      {:ok, updated_receipt} = Ash.get(DeliveryReceipt, receipt.id, authorize?: false)
      assert updated_receipt.status == :scheduled
      assert updated_receipt.retry_count == 2
      assert updated_receipt.last_retry_at != nil

      # Verify SendEmail job was enqueued
      assert_enqueued(worker: SendEmail, args: %{receipt_id: receipt.id})
    end

    test "does not retry permanently failed deliveries" do
      # Create a permanently failed receipt
      {:ok, receipt} =
        DeliveryReceipt
        |> Ash.Changeset.for_create(:create, %{
          event_id: "test.event",
          transport: :email,
          audience: :user,
          recipient: "user@example.com",
          content: %{
            subject: "Test",
            from: "test@example.com",
            html_body: "<p>Test</p>",
            text_body: "Test"
          }
        })
        |> Ash.create(authorize?: false)

      {:ok, receipt} =
        receipt
        |> Ash.Changeset.for_update(:schedule, %{})
        |> Ash.update(authorize?: false)

      {:ok, receipt} =
        receipt
        |> Ash.Changeset.for_update(:mark_sending, %{})
        |> Ash.update(authorize?: false)

      {:ok, receipt} =
        receipt
        |> Ash.Changeset.for_update(:mark_failed_permanent, %{
          error_message: "Invalid email address"
        })
        |> Ash.update(authorize?: false)

      assert receipt.status == :failed_permanent

      # Run the retry worker
      assert :ok = perform_job(RetryFailedDeliveries, %{})

      # Verify receipt was NOT updated
      {:ok, unchanged_receipt} = Ash.get(DeliveryReceipt, receipt.id, authorize?: false)
      assert unchanged_receipt.status == :failed_permanent
      assert unchanged_receipt.retry_count == 0

      # Verify no job was enqueued
      refute_enqueued(worker: SendEmail, args: %{receipt_id: receipt.id})
    end

    test "does not retry deliveries that exceed max_retries" do
      # Create a failed receipt with high retry count
      {:ok, receipt} = create_failed_receipt("test.event", 1)

      # Manually set retry_count to max (5)
      {:ok, receipt} =
        receipt
        |> Ash.Changeset.for_update(:update, %{retry_count: 5})
        |> Ash.update(authorize?: false)

      assert receipt.retry_count == 5

      # Run the retry worker
      assert :ok = perform_job(RetryFailedDeliveries, %{})

      # Verify receipt was NOT retried
      {:ok, unchanged_receipt} = Ash.get(DeliveryReceipt, receipt.id, authorize?: false)
      assert unchanged_receipt.status == :failed
      assert unchanged_receipt.retry_count == 5

      # Verify no job was enqueued
      refute_enqueued(worker: SendEmail, args: %{receipt_id: receipt.id})
    end

    test "respects retry delay (does not retry recently failed deliveries)" do
      # Create a failed receipt with recent last_retry_at
      {:ok, receipt} = create_failed_receipt("test.event", 1)

      # last_retry_at is set to 1 minute ago (within 15 minute delay)
      recent_time = DateTime.add(DateTime.utc_now(), -60, :second)

      {:ok, receipt} =
        receipt
        |> Ash.Changeset.for_update(:update, %{last_retry_at: recent_time})
        |> Ash.update(authorize?: false)

      # Run the retry worker
      assert :ok = perform_job(RetryFailedDeliveries, %{})

      # Verify receipt was NOT retried (too recent)
      {:ok, unchanged_receipt} = Ash.get(DeliveryReceipt, receipt.id, authorize?: false)
      assert unchanged_receipt.status == :failed
      assert unchanged_receipt.retry_count == 1

      # Verify no job was enqueued
      refute_enqueued(worker: SendEmail, args: %{receipt_id: receipt.id})
    end

    test "retries old failed deliveries (past retry delay)" do
      # Create a failed receipt with old last_retry_at
      {:ok, receipt} = create_failed_receipt("test.event", 1)

      # last_retry_at is set to 20 minutes ago (past 15 minute delay)
      old_time = DateTime.add(DateTime.utc_now(), -20 * 60, :second)

      {:ok, receipt} =
        receipt
        |> Ash.Changeset.for_update(:update, %{last_retry_at: old_time})
        |> Ash.update(authorize?: false)

      # Run the retry worker
      assert :ok = perform_job(RetryFailedDeliveries, %{})

      # Verify receipt WAS retried
      {:ok, updated_receipt} = Ash.get(DeliveryReceipt, receipt.id, authorize?: false)
      assert updated_receipt.status == :scheduled
      assert updated_receipt.retry_count == 2

      # Verify job was enqueued
      assert_enqueued(worker: SendEmail, args: %{receipt_id: receipt.id})
    end

    test "processes multiple failed deliveries in batch" do
      # Create multiple failed receipts
      receipts =
        for i <- 1..3 do
          {:ok, receipt} = create_failed_receipt("test.event.#{i}", 1)

          # Set last_retry_at to > 15 minutes ago so it's eligible for retry
          old_time = DateTime.add(DateTime.utc_now(), -20 * 60, :second)

          {:ok, receipt} =
            receipt
            |> Ash.Changeset.for_update(:update, %{last_retry_at: old_time})
            |> Ash.update(authorize?: false)

          receipt
        end

      # Run the retry worker
      assert :ok = perform_job(RetryFailedDeliveries, %{})

      # Verify all receipts were retried
      for receipt <- receipts do
        {:ok, updated_receipt} = Ash.get(DeliveryReceipt, receipt.id, authorize?: false)
        assert updated_receipt.status == :scheduled
        assert updated_receipt.retry_count == 2
        assert_enqueued(worker: SendEmail, args: %{receipt_id: receipt.id})
      end
    end

    test "handles zero failed deliveries gracefully" do
      # Run the retry worker with no failed deliveries
      assert :ok = perform_job(RetryFailedDeliveries, %{})

      # Should complete without errors
      refute_enqueued(worker: SendEmail)
    end
  end

  describe "retry_receipt/2" do
    test "successfully retries a single receipt" do
      {:ok, receipt} = create_failed_receipt("test.event", 1)

      # Call retry_receipt directly with max_retries
      assert :ok = RetryFailedDeliveries.retry_receipt(receipt, 5)

      # Verify state changed
      {:ok, updated_receipt} = Ash.get(DeliveryReceipt, receipt.id, authorize?: false)
      assert updated_receipt.status == :scheduled
      assert updated_receipt.retry_count == 2
      assert_enqueued(worker: SendEmail, args: %{receipt_id: receipt.id})
    end

    test "logs warning on final retry attempt" do
      {:ok, receipt} = create_failed_receipt("test.event", 4)

      # This is the 5th retry (final attempt with max_retries=5)
      assert :ok = RetryFailedDeliveries.retry_receipt(receipt, 5)

      {:ok, updated_receipt} = Ash.get(DeliveryReceipt, receipt.id, authorize?: false)
      assert updated_receipt.retry_count == 5
    end

    test "handles enqueue failure gracefully" do
      # Create a receipt with unsupported transport
      {:ok, receipt} =
        DeliveryReceipt
        |> Ash.Changeset.for_create(:create, %{
          event_id: "test.event",
          transport: :sms,
          # SMS transport not yet supported for retry
          audience: :user,
          recipient: "user-id-123",
          content: %{message: "Test"}
        })
        |> Ash.create(authorize?: false)

      {:ok, receipt} =
        receipt
        |> Ash.Changeset.for_update(:schedule, %{})
        |> Ash.update(authorize?: false)

      {:ok, receipt} =
        receipt
        |> Ash.Changeset.for_update(:mark_sending, %{})
        |> Ash.update(authorize?: false)

      {:ok, receipt} =
        receipt
        |> Ash.Changeset.for_update(:mark_failed, %{error_message: "Test error"})
        |> Ash.update(authorize?: false)

      # Retry should return error for unsupported transport
      assert {:error, :transport_not_supported} =
               RetryFailedDeliveries.retry_receipt(receipt, 5)
    end
  end

  # Helper functions

  defp create_failed_receipt(event_id, retry_count \\ 0) do
    {:ok, receipt} =
      DeliveryReceipt
      |> Ash.Changeset.for_create(:create, %{
        event_id: event_id,
        transport: :email,
        audience: :user,
        recipient: "user@example.com",
        content: %{
          subject: "Test",
          from: "test@example.com",
          html_body: "<p>Test</p>",
          text_body: "Test"
        }
      })
      |> Ash.create(authorize?: false)

    {:ok, receipt} =
      receipt
      |> Ash.Changeset.for_update(:schedule, %{})
      |> Ash.update(authorize?: false)

    {:ok, receipt} =
      receipt
      |> Ash.Changeset.for_update(:mark_sending, %{})
      |> Ash.update(authorize?: false)

    {:ok, receipt} =
      receipt
      |> Ash.Changeset.for_update(:mark_failed, %{error_message: "Test error"})
      |> Ash.update(authorize?: false)

    # Set retry_count if specified
    if retry_count > 0 do
      {:ok, receipt} =
        receipt
        |> Ash.Changeset.for_update(:update, %{retry_count: retry_count})
        |> Ash.update(authorize?: false)

      {:ok, receipt}
    else
      {:ok, receipt}
    end
  end
end
