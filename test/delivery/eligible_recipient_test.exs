defmodule AshDispatch.Delivery.EligibleRecipientTest do
  @moduledoc """
  "May this recipient be reached at all?" — asked when the recipients are
  resolved, and again at the moment of sending.

  A preference is what a person wants, and a mandatory event overrides it on
  purpose. Until 0.9.3 that override was total: a closed account still got the
  password reset, because nothing in the library had ever been told that some
  recipients must not be reached whatever the message is.
  """
  use AshDispatch.Test.InboxCase, async: false

  alias AshDispatch.EligibleRecipient
  alias AshDispatch.Test.TransportReceipt
  alias AshDispatch.Workers.SendEmail

  @moduletag :capture_log

  defmodule Blocklist do
    @moduledoc false
    @behaviour AshDispatch.EligibleRecipient

    @impl true
    def eligible?(recipient, opts) do
      report({:asked, opts[:stage], opts[:user_id], recipient})

      if opts[:user_id] in Application.get_env(:ash_dispatch, :test_closed_accounts, []) do
        {false, "account closed"}
      else
        true
      end
    end

    def report(message) do
      case Application.get_env(:ash_dispatch, :capture_pid) do
        pid when is_pid(pid) -> send(pid, message)
        _ -> :ok
      end
    end
  end

  defmodule Raising do
    @moduledoc false
    @behaviour AshDispatch.EligibleRecipient

    @impl true
    def eligible?(_recipient, _opts), do: raise("the directory is down")
  end

  defmodule Capture do
    @moduledoc false
    def send_email(params) do
      Blocklist.report({:sent_email, params})
      {:ok, %{id: "provider-id"}}
    end
  end

  setup do
    Application.put_env(:ash_dispatch, :email_backend, Capture)

    on_exit(fn ->
      Application.delete_env(:ash_dispatch, :eligible_recipient)
      Application.delete_env(:ash_dispatch, :test_closed_accounts)
      Application.delete_env(:ash_dispatch, :email_backend)
    end)

    :ok
  end

  defp close!(user), do: Application.put_env(:ash_dispatch, :test_closed_accounts, [user.id])

  defp check!(check), do: Application.put_env(:ash_dispatch, :eligible_recipient, check)

  defp asked(acc \\ []) do
    receive do
      {:asked, stage, user_id, _recipient} -> asked([{stage, user_id} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp receipt_for(event_id, user) do
    Enum.find(receipts(event_id), &(&1.user_id == user.id))
  end

  describe "without a check configured" do
    test "nothing is asked and nothing changes" do
      refute EligibleRecipient.configured?()

      kim = user("kim")
      assert {:ok, _} = send_event(:updated, [kim])

      assert receipt_for("meeting.updated", kim).status == :sent
      assert [_notification] = notifications_for(kim.id)
    end
  end

  describe "when the recipients are resolved" do
    setup do
      check!(Blocklist)
      :ok
    end

    test "an ineligible recipient gets a skipped receipt with the reason, not a silent drop" do
      kim = user("kim")
      close!(kim)

      assert {:ok, _} = send_event(:updated, [kim])

      held = receipt_for("meeting.updated", kim)
      assert held.status == :skipped
      assert held.error_message == "recipient_ineligible: account closed"

      # Held back, not delivered: no notification exists for them.
      assert notifications_for(kim.id) == []
    end

    test "the verdict is per recipient: a fan-out loses one person, not the channel" do
      kim = user("kim")
      robin = user("robin")
      close!(kim)

      assert {:ok, _} = send_event(:updated, [kim, robin])

      assert receipt_for("meeting.updated", kim).status == :skipped
      assert receipt_for("meeting.updated", robin).status == :sent
      assert notifications_for(kim.id) == []
      assert [_notification] = notifications_for(robin.id)
    end

    test "a receipt exists for every channel the recipient would have been reached on" do
      kim = user("kim")
      close!(kim)

      # Both channels of the event, not only the in-app one.
      assert {:ok, _} =
               AshDispatch.Dispatcher.dispatch("meeting.starting_soon", %{
                 meeting: meeting(),
                 participants: [kim]
               })

      held = receipts("meeting.starting_soon")
      assert Enum.map(held, & &1.transport) |> Enum.sort() == [:email, :in_app]

      for receipt <- held do
        assert receipt.status == :skipped
        assert receipt.error_message == "recipient_ineligible: account closed"
      end
    end

    test "the check is given the stage, the user and the resolved recipient" do
      kim = user("kim")
      assert {:ok, _} = send_event(:updated, [kim])

      assert_received {:asked, :resolve, user_id, recipient}
      assert user_id == kim.id
      assert recipient == kim
    end

    # The whole point: a preference is a choice, this is not.
    test "a mandatory event respects it" do
      kim = user("kim")

      # First, as 0.9.0 left it: switched off, and delivered anyway.
      put_preference!(%{
        user_id: kim.id,
        event_id: "meeting.cancelled",
        transport: :in_app,
        enabled: false
      })

      assert {:ok, _} = send_event(:cancelled, [kim])
      assert receipt_for("meeting.cancelled", kim).status == :sent

      # Now with a closed account. Mandatory or not, they are not reached.
      close!(kim)
      robin = user("robin")

      assert {:ok, _} = send_event(:cancelled, [kim, robin])

      [held] =
        Enum.filter(
          receipts("meeting.cancelled"),
          &(&1.user_id == kim.id and &1.status == :skipped)
        )

      assert held.error_message == "recipient_ineligible: account closed"

      assert Enum.any?(
               receipts("meeting.cancelled"),
               &(&1.user_id == robin.id and &1.status == :sent)
             )
    end
  end

  describe "at the moment of sending" do
    setup do
      check!(Blocklist)
      :ok
    end

    # The answer may have changed while the job waited: `delay: 86_400`, a
    # retry, a stranded job rescued hours later. This is the ask that matters
    # for a reminder scheduled yesterday for an account closed this morning.
    test "a recipient who was eligible at resolve time and is not now" do
      kim = user("kim")

      receipt =
        TransportReceipt
        |> Ash.Changeset.for_create(:create, %{
          status: :scheduled,
          event_id: "meeting.updated",
          audience: :user,
          transport: :email,
          user_id: kim.id,
          recipient: kim.email,
          subject: "Meeting moved",
          body_text: "The meeting was moved"
        })
        |> Ash.create!(authorize?: false)

      # Eligible when the letter was written.
      assert EligibleRecipient.send_verdict(receipt) == :send

      # Closed while the job waited in the queue.
      close!(kim)

      assert :ok = SendEmail.perform(%Oban.Job{args: %{"receipt_id" => receipt.id}})

      refute_received {:sent_email, _params}

      held = Ash.get!(TransportReceipt, receipt.id, authorize?: false)
      assert held.status == :skipped
      assert held.error_message == "recipient_ineligible: account closed"
    end

    test "a recipient who is still eligible is sent to" do
      kim = user("kim")

      receipt =
        TransportReceipt
        |> Ash.Changeset.for_create(:create, %{
          status: :scheduled,
          event_id: "meeting.updated",
          audience: :user,
          transport: :email,
          user_id: kim.id,
          recipient: kim.email,
          subject: "Meeting moved",
          body_text: "The meeting was moved"
        })
        |> Ash.create!(authorize?: false)

      assert :ok = SendEmail.perform(%Oban.Job{args: %{"receipt_id" => receipt.id}})

      assert_received {:sent_email, _params}
      assert Ash.get!(TransportReceipt, receipt.id, authorize?: false).status == :sent
    end

    test "the send-stage ask carries no recipient struct — a job holds ids, not structs" do
      kim = user("kim")

      receipt =
        TransportReceipt
        |> Ash.Changeset.for_create(:create, %{
          status: :scheduled,
          event_id: "meeting.updated",
          transport: :email,
          user_id: kim.id,
          recipient: kim.email
        })
        |> Ash.create!(authorize?: false)

      EligibleRecipient.send_verdict(receipt)

      assert_received {:asked, :send, user_id, nil}
      assert user_id == kim.id
    end
  end

  describe "both stages" do
    test "a delayed in-app delivery asks once; an email asks again in the worker" do
      check!(Blocklist)
      kim = user("kim")

      assert {:ok, _} = send_event(:updated, [kim])

      # `:in_app` delivers in the same breath as the dispatch, so asking twice
      # would be the same question a microsecond apart.
      assert asked() == [{:resolve, kim.id}]
    end
  end

  describe "a check that cannot answer" do
    test "a check that raises holds the delivery back and leaves the reason" do
      check!(Raising)
      kim = user("kim")

      assert {:ok, _} = send_event(:updated, [kim])

      held = receipt_for("meeting.updated", kim)
      assert held.status == :skipped
      assert held.error_message =~ "recipient_ineligible"
      assert held.error_message =~ "raised"
      assert notifications_for(kim.id) == []
    end

    test "a check that answers something else holds it back too" do
      check!(fn _recipient, _opts -> "sure, why not" end)
      kim = user("kim")

      assert {:ok, _} = send_event(:updated, [kim])
      assert receipt_for("meeting.updated", kim).status == :skipped
    end

    test "a setting that cannot be called holds it back and says so" do
      check!("MyApp.Eligibility")
      kim = user("kim")

      assert {:ok, _} = send_event(:updated, [kim])
      assert receipt_for("meeting.updated", kim).status == :skipped
    end
  end

  describe "the answers it understands" do
    test "true, :ok and {:ok, true} let a delivery through" do
      for answer <- [true, :ok, {:ok, true}] do
        check!(fn _recipient, _opts -> answer end)
        assert EligibleRecipient.verdict(%{}, stage: :send) == :send, inspect(answer)
      end
    end

    test "false, nil and {:ok, false} hold it back, with the countable reason" do
      for answer <- [false, nil, {:ok, false}] do
        check!(fn _recipient, _opts -> answer end)

        assert EligibleRecipient.verdict(%{}, stage: :send) ==
                 {:skip, "recipient_ineligible"},
               inspect(answer)
      end
    end

    test "a reason is appended, so both forms can be counted" do
      for answer <- [{false, "barred"}, {:error, "barred"}, {:ineligible, "barred"}] do
        check!(fn _recipient, _opts -> answer end)

        assert EligibleRecipient.verdict(%{}, stage: :send) ==
                 {:skip, "recipient_ineligible: barred"},
               inspect(answer)
      end
    end

    test "every form of the setting is called" do
      for {setting, expected} <- [
            {Blocklist, :send},
            {{Blocklist, :eligible?}, :send},
            {fn _recipient, _opts -> true end, :send},
            {fn _recipient, _opts -> false end, {:skip, "recipient_ineligible"}}
          ] do
        check!(setting)
        assert EligibleRecipient.verdict(%{}, stage: :send, user_id: nil) == expected
      end
    end
  end
end
