defmodule AshDispatch.Delivery.GateTest do
  @moduledoc """
  A condition on the event itself: does it go out at all?

  `should_send?/2` already answered that with a boolean and left nothing
  behind — a channel it refused was dropped, silently, and nobody could tell
  afterwards whether the event had been skipped or had never fired. A gate is
  the same decision with a record and a reason, asked again at the moment of
  sending so a delayed delivery is decided by today's answer and not by
  yesterday's.
  """
  use AshDispatch.Test.InboxCase, async: false

  alias AshDispatch.Gate
  alias AshDispatch.Test.TransportReceipt
  alias AshDispatch.Workers.SendEmail

  @moduletag :capture_log

  defmodule Capture do
    @moduledoc false
    def send_email(params) do
      AshDispatch.Test.Inbox.Gates.report({:sent_email, params})
      {:ok, %{id: "provider-id"}}
    end
  end

  setup do
    Application.put_env(:ash_dispatch, :email_backend, Capture)

    on_exit(fn ->
      Application.delete_env(:ash_dispatch, :test_gate)
      Application.delete_env(:ash_dispatch, :email_backend)
    end)

    :ok
  end

  defp gate!(answer), do: Application.put_env(:ash_dispatch, :test_gate, answer)

  defp send_reminder(participants, opts \\ []) do
    AshDispatch.Dispatcher.dispatch(
      "meeting.reminder",
      %{meeting: meeting(), participants: participants},
      %{},
      opts
    )
  end

  # Both fixtures report `{:gate_asked, a, b}`: the DSL gate as
  # `{stage, transport}`, the callback gate as `{:callback, stage}`.
  defp asks(acc \\ []) do
    receive do
      {:gate_asked, first, second} -> asks([{first, second} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp receipt!(event_id, user) do
    TransportReceipt
    |> Ash.Changeset.for_create(:create, %{
      status: :scheduled,
      event_id: event_id,
      audience: :user,
      transport: :email,
      user_id: user.id,
      recipient: user.email,
      subject: "Meeting reminder",
      body_text: "Tomorrow at nine"
    })
    |> Ash.create!(authorize?: false)
  end

  describe "without a gate" do
    test "an event that declares none is not asked, and behaves as before" do
      assert Gate.declared(%{}, "meeting.updated") == nil

      kim = user("kim")
      assert {:ok, _} = send_event(:updated, [kim])

      assert Enum.find(receipts("meeting.updated"), &(&1.user_id == kim.id)).status == :sent
      assert asks() == []
    end
  end

  describe "an open gate" do
    test "changes nothing" do
      gate!(true)
      kim = user("kim")

      assert {:ok, _} = send_reminder([kim], channels: [%{transport: :in_app}])

      assert Enum.find(receipts("meeting.reminder"), &(&1.user_id == kim.id)).status == :sent
      assert [_notification] = notifications_for(kim.id)
      assert asks() == [{:dispatch, :in_app}]
    end

    test ":ok is an open gate too" do
      gate!(:ok)
      kim = user("kim")

      assert {:ok, _} = send_reminder([kim], channels: [%{transport: :in_app}])
      assert Enum.find(receipts("meeting.reminder"), &(&1.user_id == kim.id)).status == :sent
    end
  end

  describe "a closed gate" do
    test "leaves a skipped record for every channel that would have been used" do
      gate!({false, "the meeting was cancelled"})
      kim = user("kim")

      assert {:ok, _} = send_reminder([kim])

      held = receipts("meeting.reminder")
      assert Enum.map(held, & &1.transport) |> Enum.sort() == [:email, :in_app]

      for receipt <- held do
        assert receipt.status == :skipped
        assert receipt.error_message == "event_gate_closed: the meeting was cancelled"
      end

      # Held back, not delivered.
      assert notifications_for(kim.id) == []
    end

    test "a bare false closes it with the countable reason" do
      gate!(false)
      kim = user("kim")

      assert {:ok, _} = send_reminder([kim], channels: [%{transport: :in_app}])

      [held] = receipts("meeting.reminder")
      assert held.status == :skipped
      assert held.error_message == "event_gate_closed"
    end

    test "every recipient of a fan-out gets their record" do
      gate!(false)
      kim = user("kim")
      robin = user("robin")

      assert {:ok, _} = send_reminder([kim, robin], channels: [%{transport: :in_app}])

      held = receipts("meeting.reminder")
      assert length(held) == 2
      assert Enum.all?(held, &(&1.status == :skipped))
      assert Enum.map(held, & &1.user_id) |> Enum.sort() == Enum.sort([kim.id, robin.id])
    end

    # Once per channel, not once per recipient: a gate is about the event.
    test "is asked once per channel, whatever the fan-out" do
      gate!(false)

      assert {:ok, _} =
               send_reminder([user("a"), user("b"), user("c")], channels: [%{transport: :in_app}])

      assert asks() == [{:dispatch, :in_app}]
    end
  end

  describe "a gate that raises" do
    test "does not send, and leaves a record saying so" do
      gate!(:raise)
      kim = user("kim")

      assert {:ok, _} = send_reminder([kim], channels: [%{transport: :in_app}])

      [held] = receipts("meeting.reminder")
      assert held.status == :skipped
      assert held.error_message == "event_gate_closed: the gate raised"
      assert notifications_for(kim.id) == []
    end

    test "and holds the delivery back at send time too" do
      gate!(:raise)
      kim = user("kim")
      receipt = receipt!("meeting.reminder", kim)

      assert :ok = SendEmail.perform(%Oban.Job{args: %{"receipt_id" => receipt.id}})

      refute_received {:sent_email, _params}
      held = Ash.get!(TransportReceipt, receipt.id, authorize?: false)
      assert held.status == :skipped
      assert held.error_message == "event_gate_closed: the gate raised"
    end
  end

  describe "a gate that gives no answer" do
    test "closes, rather than sending on a shrug" do
      for answer <- [nil, "yes", {:ok, false}] do
        gate!(answer)
        kim = user("kim")

        assert {:ok, _} = send_reminder([kim], channels: [%{transport: :in_app}])

        held = Enum.find(receipts("meeting.reminder"), &(&1.user_id == kim.id))
        assert held.status == :skipped, "#{inspect(answer)} should close the gate"
      end
    end
  end

  describe "at the moment of sending" do
    # The ask that makes a gate work for `time: {:in, 86_400}`: the reminder
    # was gated when it was queued, and is gated again when it is sent.
    test "a delayed delivery is decided by today's answer, not yesterday's" do
      gate!(true)
      kim = user("kim")
      receipt = receipt!("meeting.reminder", kim)

      # Open when the letter was written.
      assert Gate.send_verdict(receipt) == :send

      # Closed while the job waited in the queue.
      gate!({false, "the meeting was cancelled"})

      assert :ok = SendEmail.perform(%Oban.Job{args: %{"receipt_id" => receipt.id}})

      refute_received {:sent_email, _params}
      held = Ash.get!(TransportReceipt, receipt.id, authorize?: false)
      assert held.status == :skipped
      assert held.error_message == "event_gate_closed: the meeting was cancelled"
    end

    test "an open gate sends" do
      gate!(true)
      kim = user("kim")
      receipt = receipt!("meeting.reminder", kim)

      assert :ok = SendEmail.perform(%Oban.Job{args: %{"receipt_id" => receipt.id}})

      assert_received {:sent_email, _params}
      assert Ash.get!(TransportReceipt, receipt.id, authorize?: false).status == :sent
    end

    test "the ask carries the receipt and the stage, and no context" do
      gate!(true)
      kim = user("kim")
      receipt = receipt!("meeting.reminder", kim)

      assert Gate.send_verdict(receipt) == :send
      assert asks() == [{:send, :email}]
    end

    test "an event without a gate is not asked at send time either" do
      kim = user("kim")
      receipt = receipt!("meeting.updated", kim)

      assert Gate.send_verdict(receipt) == :send
      assert asks() == []
    end
  end

  describe "a gate declared as a callback on the event module" do
    test "is asked at dispatch and at send" do
      gate!(false)
      kim = user("kim")

      assert {:ok, _} =
               AshDispatch.Dispatcher.dispatch("meeting.archived", %{
                 meeting: meeting(),
                 participants: [kim]
               })

      [held] = receipts("meeting.archived")
      assert held.status == :skipped
      assert held.error_message == "event_gate_closed"
      assert asks() == [{:callback, :dispatch}]

      gate!(true)
      assert Gate.send_verdict(receipt!("meeting.archived", kim)) == :send
      assert asks() == [{:callback, :send}]
    end
  end

  describe "declared/2 — where a gate is found" do
    test "the event config wins over everything" do
      assert Gate.declared(%{gate: {Mod, :fun}}, "meeting.reminder") == {Mod, :fun}
      assert Gate.declared([gate: {Mod, :fun}], "meeting.reminder") == {Mod, :fun}
    end

    test "then the registry" do
      assert Gate.declared(%{}, "meeting.reminder") ==
               {AshDispatch.Test.Inbox.Gates, :open?}
    end

    test "then the event module's callback" do
      assert Gate.declared(%{}, "meeting.archived") ==
               {:callback, AshDispatch.Test.Inbox.MeetingArchived}
    end

    test "and an unknown event has none" do
      assert Gate.declared(%{}, "nothing.at_all") == nil
      assert Gate.declared(nil, nil) == nil
    end
  end

  describe "a gate that cannot be called" do
    test "closes, and says what is wrong" do
      assert {:closed, "event_gate_closed: the gate cannot be called"} =
               Gate.dispatch_verdict(
                 %AshDispatch.Context{event_id: "meeting.updated", data: %{}},
                 %AshDispatch.Channel{transport: :email, audience: :user},
                 %{gate: "MyApp.Gates"}
               )
    end

    test "a function of the wrong arity is not called" do
      assert {:closed, _reason} =
               Gate.dispatch_verdict(
                 %AshDispatch.Context{event_id: "meeting.updated", data: %{}},
                 %AshDispatch.Channel{transport: :email, audience: :user},
                 %{gate: fn -> true end}
               )
    end
  end
end
