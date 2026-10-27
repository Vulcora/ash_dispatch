defmodule AshDispatch.PreviewSideEffectsTest do
  @moduledoc """
  What a preview must NOT do — found in review before the first release:

  - run `generate_send_variables/2`, where events mint tokens and write rows
    (an admin page listing events minted one per event per load);
  - read customer records or query recipients when the caller asked for
    sample data only (the `EmailEvent` list);
  - lose the subject and sender of a non-email channel in the ManualTrigger
    preview maps.
  """
  use AshDispatch.Test.PreviewCase, async: false

  alias AshDispatch.Preview
  alias AshDispatch.Resources.ManualTrigger.Helpers

  describe "generate_send_variables/2" do
    test "a preview never runs it — the manual (dispatch/3) path" do
      assert {:ok, [_ | _]} = Preview.render("booking.reminder")
      refute_received {:minted, _}
    end

    test "a preview never runs it — the action-triggered (notifier) path" do
      booking = create_booking!()
      assert_received {:minted, "booking.confirmed"}

      assert {:ok, [_]} = Preview.render("booking.confirmed", {:record, booking.id})
      refute_received {:minted, _}
    end

    test "nor do the facades built on it" do
      assert {:ok, _} = AshDispatch.preview("booking.reminder")

      assert [_ | _] = AshDispatch.Test.render_all(only: ["booking.reminder"])

      refute_received {:minted, _}
    end

    test "the real send still runs it" do
      booking = create_booking!()
      assert_received {:minted, "booking.confirmed"}

      {:ok, _} = AshDispatch.Dispatcher.dispatch("booking.reminder", %{booking: booking})
      assert_received {:minted, "booking.reminder"}
    end
  end

  describe "sample-only previews" do
    test "resolve_recipients?: false renders without asking who the recipient is" do
      assert {:ok, [letter]} =
               Preview.render("booking.confirmed", :sample, seed: 1, resolve_recipients?: false)

      assert letter.recipient == nil
      assert letter.subject =~ "confirmed"
    end
  end

  describe "ManualTrigger preview maps" do
    test "a non-email channel keeps its subject and sender, as before" do
      assert {:ok, [in_app]} =
               Helpers.preview_trigger("booking.reminder", %{}, %{transport: :in_app}, nil, nil)

      assert in_app.subject == "See you soon — B-SAMPLE"
      assert in_app.from_address == "noreply@example.com"
      assert in_app.notification_title == "Reminder sent"
    end
  end
end
