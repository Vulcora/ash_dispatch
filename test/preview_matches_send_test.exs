defmodule AshDispatch.PreviewMatchesSendTest do
  @moduledoc """
  The guard against drift: render a letter with `AshDispatch.Preview`, send
  the same letter for real, and compare what the email backend was handed —
  subject, HTML, text, sender, reply address, attachments, headers and
  recipient — field by field.

  If this fails, the send path has gained a step the preview does not take.
  That is the bug: a preview that is believed and wrong is worse than none.

  Both send paths are covered: an action-triggered event (the notifier) and a
  manual one (`Dispatcher.dispatch/3`).
  """
  use AshDispatch.Test.PreviewCase, async: false

  alias AshDispatch.Preview

  defp envelope(%Preview.Rendered{} = rendered) do
    Map.take(rendered, [
      :to,
      :from,
      :subject,
      :reply_to,
      :html_body,
      :text_body,
      :attachments,
      :headers
    ])
  end

  defp envelope(params) when is_map(params) do
    params
    |> Map.put_new(:headers, %{})
    |> Map.take([
      :to,
      :from,
      :subject,
      :reply_to,
      :html_body,
      :text_body,
      :attachments,
      :headers
    ])
  end

  test "booking.confirmed (notifier): the preview of the record is what was sent" do
    booking = create_booking!(%{guest_name: "Maja", guest_email: "maja@example.com"})

    assert [sent] = sent_emails()
    assert {:ok, [preview]} = Preview.render("booking.confirmed", {:record, booking.id})

    assert preview.error == nil
    assert envelope(preview) == envelope(sent)

    # And it is a real letter, not two empty ones that happen to agree.
    assert sent.to == "maja@example.com"
    assert sent.subject == "Booking #{booking.reference} confirmed"
    assert sent.html_body =~ "Hi Maja"
    assert sent.text_body =~ booking.reference
    assert sent.from == {"Bookings", "bookings@example.com"}
    assert sent.reply_to == "host@example.com"
    assert sent.headers == %{"X-Entity-Ref-ID" => booking.reference}
    assert [%{filename: "booking.ics", content_type: "text/calendar"}] = sent.attachments
  end

  test "booking.reminder (dispatch/3): the preview of the data is what was sent, per channel" do
    booking = create_booking!()
    _confirmation = sent_emails()

    assert {:ok, _} =
             AshDispatch.Dispatcher.dispatch("booking.reminder", %{booking: booking})

    sent = sent_emails()
    assert length(sent) == 2

    assert {:ok, previews} =
             Preview.render("booking.reminder", %{booking: booking}, transport: :email)

    assert length(previews) == 2

    for preview <- previews do
      assert preview.error == nil
      assert envelope(preview) in Enum.map(sent, &envelope/1)
    end

    assert Enum.map(previews, & &1.subject) |> Enum.sort() ==
             Enum.sort([
               "See you soon — #{booking.reference}",
               "Guest reminder: #{booking.reference}"
             ])
  end

  test "the stored receipt holds what the preview shows" do
    booking = create_booking!()

    {:ok, [preview]} = Preview.render("booking.confirmed", {:record, booking.id})

    [receipt] =
      AshDispatch.Test.TransportReceipt
      |> Ash.read!(authorize?: false)
      |> Enum.filter(&(&1.event_id == "booking.confirmed" and &1.recipient == preview.recipient))
      |> Enum.filter(&(&1.subject == preview.subject))

    assert receipt.body_html == preview.html_body
    assert receipt.body_text == preview.text_body
    assert receipt.status == :sent
  end
end
