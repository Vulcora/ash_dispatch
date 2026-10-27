defmodule AshDispatch.Workers.RetryAccountingTest do
  @moduledoc """
  BACKLOG #1: a failed delivery must be retried ONCE per retry, and counted
  once.

  - The `RetryFailedDeliveries` cron ran the `:retry` action — whose
    `EnqueueRetryJob` change enqueues a job — and then enqueued another one
    itself. An in-app retry, which delivers inline, was delivered twice.
  - The send workers' `unique` states left out `:retryable`, so a cron retry
    landed beside the job Oban was already going to retry.
  - `retry_count` is counted by `:retry` alone, never by `:mark_failed`.

  The receipt here is the real `DeliveryReceipt.Base` (via `use
  AshDispatch.Setup`). It has a Postgres data layer and no database, so the
  actions are built as changesets and inspected, never run.
  """
  use ExUnit.Case, async: true

  alias AshDispatch.Test.Setup.Deliveries.DeliveryReceipt

  defp receipt(attrs) do
    struct(
      DeliveryReceipt,
      Map.merge(
        %{
          id: Ash.UUID.generate(),
          event_id: "booking.reminder",
          transport: :email,
          audience: :user,
          recipient: "a@example.com",
          content: %{},
          retry_count: 1,
          status: :failed
        },
        attrs
      )
    )
    |> Ash.Resource.put_metadata(:selected, nil)
    |> Map.put(:__meta__, %Ecto.Schema.Metadata{state: :loaded, source: "delivery_receipts"})
  end

  describe "retry_count" do
    test ":retry counts the retry" do
      changeset = Ash.Changeset.for_update(receipt(%{}), :retry, %{})
      assert Ash.Changeset.get_attribute(changeset, :retry_count) == 2
    end

    test ":mark_failed does not — a failure is not a retry" do
      changeset = Ash.Changeset.for_update(receipt(%{status: :sending}), :mark_failed, %{})
      refute Map.has_key?(changeset.attributes, :retry_count)
      assert Ash.Changeset.get_attribute(changeset, :retry_count) == 1
    end
  end

  describe "the cron enqueues once" do
    test ":retry enqueues by itself on the admin path" do
      changeset = Ash.Changeset.for_update(receipt(%{}), :retry, %{})
      assert changeset.after_action != []
    end

    test "the cron's :retry carries ash_dispatch_enqueue?: false, and then enqueues nothing" do
      changeset =
        receipt(%{})
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_context(%{ash_dispatch_enqueue?: false})
        |> Ash.Changeset.for_update(:retry, %{})

      assert changeset.after_action == []
    end
  end

  describe "unique jobs cover Oban's own retries" do
    for worker <- [AshDispatch.Workers.SendEmail, AshDispatch.Workers.SendSMS] do
      test "#{inspect(worker)}" do
        states = unquote(worker).__opts__()[:unique][:states]
        assert :retryable in states
        assert :available in states and :scheduled in states and :executing in states
      end
    end
  end
end
