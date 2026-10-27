defmodule AshDispatch.Resources.ManualTriggerOverrideTest do
  @moduledoc """
  BACKLOG #2: the `:trigger` action's `recipient_email`, `audience`,
  `transport` and `skip_preferences` were packed into the template variables
  and read by nothing. "Send a test to myself" mailed the real recipient.

  They are dispatch options now (`Dispatcher.dispatch/4`), and a recipient
  override is total: only email channels go out, each to the override
  address, and the receipt records whom it replaced.
  """
  use AshDispatch.Test.PreviewCase, async: false

  alias AshDispatch.Test.Preview.ManualTrigger
  alias AshDispatch.Test.TransportReceipt

  setup do
    previous = Application.fetch_env(:ash_dispatch, :audiences)
    Application.put_env(:ash_dispatch, :audiences, [:user, :admin])

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ash_dispatch, :audiences, value)
        :error -> Application.delete_env(:ash_dispatch, :audiences)
      end
    end)

    booking = create_booking!(%{guest_name: "Hugo", guest_email: "hugo@example.com"})
    # The confirmation the create sent is not what these tests are about.
    _ = sent_emails()

    %{booking: booking}
  end

  defp trigger(attrs) do
    ManualTrigger
    |> Ash.Changeset.for_create(:trigger, attrs)
    |> Ash.create(authorize?: false)
  end

  defp receipts(event_id) do
    TransportReceipt
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.event_id == event_id))
  end

  test "recipient_email: the letter goes to the override, never to the real recipient", %{
    booking: booking
  } do
    assert {:ok, trigger} =
             trigger(%{
               event_id: "booking.reminder",
               context_data: %{booking_id: booking.id},
               recipient_email: "me@example.com"
             })

    sent = sent_emails()

    # Both email channels, rendered as the guest's letter, addressed to me.
    assert length(sent) == 2
    assert Enum.all?(sent, &(&1.to == "me@example.com"))
    refute Enum.any?(sent, &(&1.to == "hugo@example.com"))
    assert Enum.any?(sent, &(&1.subject == "See you soon — #{booking.reference}"))

    # The in-app channel cannot be redirected, so it is not dispatched at all.
    receipts = receipts("booking.reminder")
    assert Enum.map(receipts, & &1.transport) |> Enum.uniq() == [:email]
    assert length(trigger.delivery_receipt_ids) == 2

    for receipt <- receipts do
      assert receipt.recipient == "me@example.com"
      assert receipt.user_id == nil

      assert %{
               recipient_email: "me@example.com",
               original_recipient: "hugo@example.com",
               skip_preferences: false
             } = receipt.content.manual_override
    end
  end

  test "transport and audience filter the channels", %{booking: booking} do
    # booking.reminder also has an in-app channel. Without the filter it is
    # dispatched too (and fails here: the suite configures no in-app
    # recipient field) — with it, only the two email channels run.
    assert {:ok, _} =
             trigger(%{
               event_id: "booking.reminder",
               context_data: %{booking_id: booking.id},
               transport: :email,
               audience: :user
             })

    assert length(sent_emails()) == 2
    assert Enum.map(receipts("booking.reminder"), & &1.transport) == [:email, :email]
  end

  test "without options it is an ordinary dispatch to the resolved recipient", %{
    booking: booking
  } do
    assert {:ok, _} =
             trigger(%{event_id: "booking.reminder", context_data: %{booking_id: booking.id}})

    assert Enum.map(sent_emails(), & &1.to) == ["hugo@example.com", "hugo@example.com"]
  end

  test "an override is rejected when blank" do
    assert {:error, :invalid_recipient_email} =
             AshDispatch.Dispatcher.dispatch("booking.reminder", %{}, %{}, recipient_email: "  ")
  end

  describe "skip_preferences" do
    setup do
      previous = Application.fetch_env(:ash_dispatch, :user_preference)
      Application.put_env(:ash_dispatch, :user_preference, AshDispatch.Test.Preview.DenyAll)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:ash_dispatch, :user_preference, value)
          :error -> Application.delete_env(:ash_dispatch, :user_preference)
        end
      end)
    end

    test "the opt-out gate is bypassed only when the dispatch asked for it" do
      receipt = %{user_id: Ash.UUID.generate()}
      channel = %AshDispatch.Channel{transport: :email, audience: :user}
      context = %AshDispatch.Context{event_id: "booking.reminder", data: %{}}

      gate = fn context ->
        AshDispatch.Transports.Preferences.with_consent(receipt, context, channel, [], fn ->
          :delivered
        end)
      end

      overridden =
        AshDispatch.Context.merge_metadata(context, %{
          ash_dispatch_override: %{
            recipient_email: nil,
            skip_preferences: true,
            actor_id: nil
          }
        })

      assert gate.(overridden) == :delivered
      # Without the override the checker says no, and the gate goes to mark
      # the receipt skipped — which this bare map cannot be.
      assert_raise ArgumentError, fn -> gate.(context) end
    end
  end
end
