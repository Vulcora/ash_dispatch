defmodule AshDispatch.ReasonCodesPostgresTest do
  @moduledoc """
  Storing the reason code, against a real Postgres — which is the only place
  the two things that matter about it can be told apart.

  **With the option off** the three actions must be exactly what they were in
  0.9.4-rc.5, atomic included, so a host's `Ash.bulk_update(query, :skip, …)`
  still runs under the default atomic strategy.

  **With it on** the key must be merged into the stored jsonb server side. The
  first version wrote back a whole content map read a moment earlier, which
  undoes anything that landed in between — and what lands in between is
  `ScrubSensitiveContent`, so a reset-link body came back to the row.
  """
  use AshDispatch.Test.PerTenantCase, async: false

  alias AshDispatch.Reason
  alias AshDispatch.Test.PerTenant
  alias AshDispatch.Workers.ScrubSensitiveContent

  require Ash.Query

  @moduletag :postgres

  defp build!(resource, attrs \\ %{}) do
    resource
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          event_id: "ticket.otp_issued",
          transport: :email,
          audience: :user,
          recipient: "user@example.com",
          subject: "Your code",
          body_text: "Your code is 123456",
          body_html: "<p>123456</p>",
          content: %{"text_body" => "Your code is 123456", "subject" => "Your code"}
        },
        attrs
      )
    )
    |> Ash.create!(authorize?: false)
  end

  defp reload(resource, receipt), do: Ash.get!(resource, receipt.id, authorize?: false)

  describe "with reason_codes: false — the default" do
    test "the three actions write no code at all" do
      receipt = build!(PerTenant.PublicReceipt)

      updated =
        receipt
        |> Ash.Changeset.for_update(:skip, %{error_message: "delivery_dry_run"})
        |> Ash.update!(authorize?: false)

      refute Map.has_key?(updated.content, "reason_code")
    end

    test "and Reason.of/1 still answers, by classifying the sentence" do
      receipt = build!(PerTenant.PublicReceipt)

      updated =
        receipt
        |> Ash.Changeset.for_update(:skip, %{error_message: "delivery_dry_run"})
        |> Ash.update!(authorize?: false)

      # The whole point of the default: a host gets the counting with no
      # column, no backfill and no row touched.
      assert Reason.of(updated) == :delivery_dry_run
    end

    test ":skip is atomic again, so a host's bulk_update still works" do
      # This is what `require_atomic? false` broke. `strategy: [:atomic]`
      # refuses rather than silently falling back to streaming, so the
      # assertion is the whole finding.
      for id <- 1..3 do
        build!(PerTenant.PublicReceipt, %{recipient: "bulk-#{id}@example.com"})
      end

      assert %Ash.BulkResult{status: :success, records: records} =
               PerTenant.PublicReceipt
               |> Ash.Query.filter(status == :pending)
               |> Ash.bulk_update(:skip, %{error_message: "delivery_blocked"},
                 strategy: [:atomic],
                 return_records?: true,
                 authorize?: false
               )

      assert length(records) == 3
      assert Enum.all?(records, &(&1.status == :skipped))
    end

    test ":mark_failed_permanent is atomic too" do
      # `:create` does not accept a status, so the receipt gets there the way
      # a real one does.
      build!(PerTenant.PublicReceipt, %{recipient: "perm@example.com"})
      |> Ash.Changeset.for_update(:mark_failed, %{error_message: "first"})
      |> Ash.update!(authorize?: false)

      assert %Ash.BulkResult{status: :success, records: [_]} =
               PerTenant.PublicReceipt
               |> Ash.Query.filter(status == :failed)
               |> Ash.bulk_update(:mark_failed_permanent, %{error_message: "gone"},
                 strategy: [:atomic],
                 return_records?: true,
                 authorize?: false
               )
    end
  end

  describe "with reason_codes: true" do
    test "the code is written beside the sentence" do
      receipt = build!(PerTenant.ReasonCodeReceipt)

      receipt
      |> Ash.Changeset.for_update(:skip, %{error_message: "delivery_dry_run"})
      |> Ash.update!(authorize?: false)

      # Re-read: the struct handed back is ours, the row is the answer. The
      # first version of the merge produced a jsonb ARRAY in the column and
      # the returned struct hid it.
      stored = reload(PerTenant.ReasonCodeReceipt, receipt)

      assert stored.content["reason_code"] == "delivery_dry_run"
      assert Reason.of(stored) == :delivery_dry_run
    end

    test "and the content the receipt already held is still there" do
      receipt = build!(PerTenant.ReasonCodeReceipt)

      receipt
      |> Ash.Changeset.for_update(:mark_failed, %{error_message: "550 mailbox full"})
      |> Ash.update!(authorize?: false)

      stored = reload(PerTenant.ReasonCodeReceipt, receipt)

      assert stored.content["subject"] == "Your code"
      assert stored.content["reason_code"] == "other"
      assert Reason.of(stored) == :other
    end

    test "a transition with no reason writes no code" do
      receipt = build!(PerTenant.ReasonCodeReceipt)

      receipt
      |> Ash.Changeset.for_update(:skip, %{})
      |> Ash.update!(authorize?: false)

      refute Map.has_key?(reload(PerTenant.ReasonCodeReceipt, receipt).content, "reason_code")
    end
  end

  describe "a merge that cannot run" do
    test "costs the code and not the transition" do
      # The rescue in `PutReasonCode` claimed to keep the transition and could
      # not: an after_action hook runs inside the action's own transaction, so
      # a failed statement aborts it and the COMMIT fails whatever the hook
      # returns. The merge runs in a savepoint now, so this is a real rescue.
      #
      receipt = build!(PerTenant.ReasonCodeReceipt)

      # A trigger that raises on any UPDATE that CHANGES `content`, and on
      # nothing else. The `:skip` action's own statement sets status,
      # error_message and updated_at, so it goes through; the hook's merge is
      # the only thing that breaks, which is the shape being tested.
      PerTenant.Repo.query!("""
      create or replace function prune_test_refuse_content() returns trigger as $$
      begin
        if NEW.content is distinct from OLD.content then
          raise exception 'content is refused';
        end if;
        return NEW;
      end;
      $$ language plpgsql
      """)

      PerTenant.Repo.query!("""
      create trigger refuse_content before update on "pt_reason_receipts"
      for each row execute function prune_test_refuse_content()
      """)

      # The transition itself goes through, which is the whole claim. The
      # trigger is dropped here rather than in `on_exit`: the repo this test
      # started is already gone by the time those run.
      updated =
        try do
          receipt
          |> Ash.Changeset.for_update(:skip, %{error_message: "delivery_dry_run"})
          |> Ash.update!(authorize?: false)
        after
          PerTenant.Repo.query!(~s(drop trigger if exists refuse_content on "pt_reason_receipts"))

          PerTenant.Repo.query!("drop function if exists prune_test_refuse_content()")
        end

      assert updated.status == :skipped

      stored = reload(PerTenant.ReasonCodeReceipt, receipt)

      assert stored.status == :skipped
      assert stored.error_message == "delivery_dry_run"
      # The code is what was lost, and `Reason.of/1` still answers from the
      # sentence — which is why losing it is survivable.
      refute Map.has_key?(stored.content, "reason_code")
      assert Reason.of(stored) == :delivery_dry_run
    end
  end

  describe "a scrub that lands between the read and the write" do
    test "is not undone — the key is merged, not the map written back" do
      receipt = build!(PerTenant.ReasonCodeReceipt)

      # The struct the retry worker read in its batch, before the scrub.
      stale = receipt

      # The scrub runs: the body copies leave `content` and `body_text`
      # becomes the marker.
      {1, _} =
        PerTenant.Repo.update_all(
          ScrubSensitiveContent.scrub_query(
            "pt_reason_receipts",
            ["ticket.otp_issued"],
            DateTime.add(DateTime.utc_now(), 3600, :second),
            DateTime.add(DateTime.utc_now(), 3600, :second)
          ),
          []
        )

      # Now the worker writes its outcome from the STALE struct.
      stale
      |> Ash.Changeset.for_update(:mark_failed, %{error_message: "delivery_blocked"})
      |> Ash.update!(authorize?: false)

      after_write = reload(PerTenant.ReasonCodeReceipt, receipt)

      # The code is there...
      assert after_write.content["reason_code"] == "delivery_blocked"
      # ...and the scrubbed body did NOT come back.
      refute Map.has_key?(after_write.content, "text_body")
      assert after_write.body_text == ScrubSensitiveContent.marker()
    end

    test "the same for :skip" do
      receipt = build!(PerTenant.ReasonCodeReceipt)
      stale = receipt

      {1, _} =
        PerTenant.Repo.update_all(
          ScrubSensitiveContent.scrub_query(
            "pt_reason_receipts",
            ["ticket.otp_issued"],
            DateTime.add(DateTime.utc_now(), 3600, :second),
            DateTime.add(DateTime.utc_now(), 3600, :second)
          ),
          []
        )

      stale
      |> Ash.Changeset.for_update(:skip, %{error_message: "user_opted_out"})
      |> Ash.update!(authorize?: false)

      after_write = reload(PerTenant.ReasonCodeReceipt, receipt)

      assert after_write.content["reason_code"] == "user_opted_out"
      refute Map.has_key?(after_write.content, "text_body")
    end
  end
end
