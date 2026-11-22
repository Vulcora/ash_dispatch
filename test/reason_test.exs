defmodule AshDispatch.ReasonTest do
  @moduledoc """
  The reason a letter was held back, as a code beside the sentence.

  `error_message` is prose written for a person, and this library rewords it
  whenever the prose can be clearer. Three hosts independently matched
  substrings against it to count their held-back deliveries, which means three
  hosts' dashboards break the next time a sentence improves.

  Two halves are pinned here: that every sentence the library writes
  classifies to a code of the closed list (and that a sentence from anywhere
  else is `:other`), and that the code is actually written onto the receipt
  beside the sentence, in `content`, with no migration.
  """
  use ExUnit.Case, async: true

  alias AshDispatch.DeliveryMode
  alias AshDispatch.EligibleRecipient
  alias AshDispatch.Gate
  alias AshDispatch.Reason
  alias AshDispatch.Test.StrictReceipt
  alias AshDispatch.Transports.Preferences

  describe "the closed list" do
    test "is closed, and :other is in it" do
      assert :other in Reason.codes()
      assert Reason.code?(:user_opted_out)
      refute Reason.code?(:something_new)
    end

    test "every code is an atom, so a count groups on values and not prose" do
      assert Enum.all?(Reason.codes(), &is_atom/1)
    end
  end

  describe "classify/1 covers the reasons the library itself writes" do
    # The reason functions the library has always exported for counting. If
    # one of them is reworded, this test says so rather than a host's
    # dashboard quietly going to zero.
    test "the four public reason/0,1 functions" do
      assert Reason.classify(Gate.reason()) == :event_gate_closed
      assert Reason.classify(EligibleRecipient.reason()) == :recipient_ineligible
      assert Reason.classify(Preferences.reason()) == :user_opted_out
      assert Reason.classify(DeliveryMode.reason(:blocked)) == :delivery_blocked
      assert Reason.classify(DeliveryMode.reason(:dry_run)) == :delivery_dry_run
      assert Reason.classify(DeliveryMode.reason(:not_allowed)) == :delivery_not_allowed
      assert Reason.classify(DeliveryMode.reason(:legacy_email)) == :delivery_blocked
    end

    test "a reason with detail appended keeps its code" do
      assert Reason.classify(Gate.reason() <> ": the gate raised") == :event_gate_closed

      assert Reason.classify(EligibleRecipient.reason() <> ": account closed") ==
               :recipient_ineligible
    end

    test "the sentences written inline by the workers and transports" do
      cases = [
        {"notification already read", :skip_if_read},
        {"User opted out of this email category", :user_opted_out},
        {"no email_backend configured", :backend_not_configured},
        {"backend did not send", :backend_skipped},
        {"transport_not_implemented", :transport_not_implemented},
        {"Unknown transport: :carrier_pigeon", :transport_unknown},
        {"No webhook_url configured", :webhook_url_missing},
        {"webhook_url_env SLACK_URL is not set", :webhook_url_missing},
        {"no_pubsub_module", :no_pubsub_module},
        {"no_user_id", :no_user_id},
        {"throttled", :throttled},
        {"the content was scrubbed from the receipt, not sent", :content_scrubbed},
        {"sensitive content already scrubbed from the receipt, not sent", :content_scrubbed},
        {"sensitive event's receipt has no body, not sent", :no_body},
        {"sensitive event's receipt has no text, not sent", :no_body},
        {"the job carries no body and the receipt has nothing to send, not sent", :no_body},
        {"Stranded in :scheduled for 48h with no live job — too old to send.", :stranded},
        {"Stranded in :sending with no live job — returned for retry.", :stranded},
        {"Failed to enqueue retry job: :timeout", :enqueue_failed}
      ]

      for {message, code} <- cases do
        assert Reason.classify(message) == code, "#{inspect(message)} classified wrong"
        assert Reason.code?(code), "#{inspect(code)} is not in the closed list"
      end
    end

    test "the opt-out sentence the preferences transport writes" do
      message = "Recipient \"3f2a\" opted out of \"orders.created\" via :email, skipping"

      assert Reason.classify(message) == :user_opted_out
    end
  end

  describe "classify/1 and everything the library did not write" do
    test "a backend's own reason is :other, not guessed at" do
      assert Reason.classify("550 mailbox full") == :other
      assert Reason.classify("suppressed: on our own blocklist") == :other
      assert Reason.classify("Resend rejected the domain") == :other
    end

    test "no reason at all is nil, not :other" do
      assert Reason.classify(nil) == nil
      assert Reason.classify("") == nil
    end

    test "an atom that is a code passes through; one that is not is :other" do
      assert Reason.classify(:throttled) == :throttled
      assert Reason.classify(:nothing_like_it) == :other
    end
  end

  describe "of/1" do
    test "reads the stored code, atom or string keys" do
      assert Reason.of(%{content: %{"reason_code" => "delivery_dry_run"}}) == :delivery_dry_run
      assert Reason.of(%{content: %{reason_code: "delivery_dry_run"}}) == :delivery_dry_run
    end

    test "a stored code outside the list is :other, never a new atom" do
      before = :erlang.system_info(:atom_count)

      assert Reason.of(%{content: %{"reason_code" => "invented_by_a_host"}}) == :other

      assert :erlang.system_info(:atom_count) == before
    end

    test "falls back on the sentence — which is how a pre-0.9.4 receipt answers" do
      assert Reason.of(%{content: %{}, error_message: "delivery_dry_run"}) == :delivery_dry_run
      assert Reason.of(%{error_message: "delivery_dry_run"}) == :delivery_dry_run
    end

    test "the stored code wins over the sentence" do
      receipt = %{content: %{"reason_code" => "throttled"}, error_message: "delivery_dry_run"}

      assert Reason.of(receipt) == :throttled
    end

    test "a receipt that was sent has no reason" do
      assert Reason.of(%{content: %{}, error_message: nil}) == nil
      assert Reason.of(%{}) == nil
    end
  end

  describe "the code is written onto the receipt" do
    defp receipt!(status) do
      StrictReceipt
      |> Ash.Changeset.for_create(:create, %{
        status: status,
        event_id: "ticket.created",
        transport: :email,
        recipient: "user@example.com",
        content: %{"policy" => "always"}
      })
      |> Ash.create!(authorize?: false)
    end

    defp update!(receipt, action, attrs) do
      receipt
      |> Ash.Changeset.for_update(action, attrs)
      |> Ash.update!(authorize?: false)
    end

    test ":skip writes it, beside the sentence and without touching the letter" do
      updated =
        :pending
        |> receipt!()
        |> update!(:skip, %{error_message: DeliveryMode.reason(:dry_run)})

      assert updated.error_message == "delivery_dry_run"
      assert updated.content["reason_code"] == "delivery_dry_run"
      # The content the receipt already carried is still there.
      assert updated.content["policy"] == "always"
      assert Reason.of(updated) == :delivery_dry_run
    end

    test ":mark_failed writes it" do
      updated =
        :sending
        |> receipt!()
        |> update!(:mark_failed, %{error_message: "Stranded in :sending with no live job."})

      assert Reason.of(updated) == :stranded
    end

    test ":mark_failed_permanent writes it" do
      updated =
        :sending
        |> receipt!()
        |> update!(:mark_failed_permanent, %{error_message: "the job carries no body, not sent"})

      assert Reason.of(updated) == :no_body
    end

    test "a backend's own reason is recorded as :other, and the sentence is kept whole" do
      updated =
        :sending
        |> receipt!()
        |> update!(:mark_failed, %{error_message: "550 mailbox full"})

      assert updated.error_message == "550 mailbox full"
      assert Reason.of(updated) == :other
    end

    test "a transition with no reason writes no code" do
      updated = :pending |> receipt!() |> update!(:skip, %{})

      refute Map.has_key?(updated.content, "reason_code")
      assert Reason.of(updated) == nil
    end

    test "the key is never carried twice, whichever spelling the content had" do
      updated =
        :pending
        |> receipt!()
        |> update!(:skip, %{error_message: "throttled"})
        |> Ash.Changeset.for_update(:skip, %{error_message: "no_user_id"})
        |> then(fn changeset -> Ash.Changeset.get_attribute(changeset, :content) end)

      assert Map.keys(updated) |> Enum.count(&(to_string(&1) == "reason_code")) == 1
    end
  end
end
