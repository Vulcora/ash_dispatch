defmodule AshDispatch.Resources.ReceiptCancelTest do
  @moduledoc """
  A delivery that has not gone yet can be stopped (`:cancel`), and a receipt
  says when its job is due (`scheduled_for`).

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
          event_id: "weekly.letter",
          transport: :email,
          audience: :user,
          recipient: "a@example.com",
          content: %{},
          retry_count: 0,
          status: :scheduled,
          oban_job_id: 42
        },
        attrs
      )
    )
    |> Ash.Resource.put_metadata(:selected, nil)
    |> Map.put(:__meta__, %Ecto.Schema.Metadata{state: :loaded, source: "delivery_receipts"})
  end

  defp cancel(attrs),
    do: Ash.Changeset.for_update(receipt(attrs), :cancel, %{error_message: "Stopped by Tavus"})

  describe ":cancel" do
    test "a delivery that has not gone yet is skipped, with the reason, and its job cancelled" do
      for status <- [:pending, :scheduled, :batched] do
        changeset = cancel(%{status: status})
        assert changeset.valid?, "#{status}: #{inspect(changeset.errors)}"
        assert Ash.Changeset.get_attribute(changeset, :status) == :skipped
        assert Ash.Changeset.get_attribute(changeset, :error_message) == "Stopped by Tavus"
        # the job is cancelled after the receipt is written
        assert changeset.after_action != []
      end
    end

    test "one that is on its way or done cannot be called back" do
      for status <- [:sending, :sent, :failed, :failed_permanent, :skipped, :digested] do
        refute cancel(%{status: status}).valid?, "#{status} should not be cancellable"
      end
    end
  end

  describe "scheduled_for" do
    test ":schedule takes the time the job is due" do
      due = ~U[2026-11-30 06:00:00.000000Z]

      changeset =
        Ash.Changeset.for_update(receipt(%{status: :pending}), :schedule, %{
          oban_job_id: 7,
          scheduled_for: due
        })

      assert changeset.valid?
      assert Ash.Changeset.get_attribute(changeset, :scheduled_for) == due
    end

    test ":release, a digest's lone email, takes it too" do
      due = ~U[2026-11-30 06:00:00.000000Z]

      changeset =
        Ash.Changeset.for_update(receipt(%{status: :batched}), :release, %{
          oban_job_id: 7,
          scheduled_for: due
        })

      assert changeset.valid?
      assert Ash.Changeset.get_attribute(changeset, :scheduled_for) == due
    end
  end
end
