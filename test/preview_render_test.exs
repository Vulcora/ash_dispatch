defmodule AshDispatch.PreviewRenderTest do
  @moduledoc """
  `AshDispatch.Preview` — the catalogue, the three sources, the filters and
  the seed. Parity with the real send is `AshDispatch.PreviewMatchesSendTest`.
  """
  use AshDispatch.Test.PreviewCase, async: false

  alias AshDispatch.Preview
  alias AshDispatch.Preview.Rendered

  describe "events/0" do
    test "one row per event × channel, with the variant and the metadata" do
      rows = Enum.filter(Preview.events(), &(&1.event_id == "booking.reminder"))

      assert [
               %{transport: :email, audience: :user, variant: nil},
               %{transport: :email, audience: :user, variant: "host"},
               %{transport: :in_app, audience: :user}
             ] = Enum.sort_by(rows, &{&1.transport, to_string(&1.variant)})

      row = hd(rows)
      assert row.module == AshDispatch.Test.Preview.BookingReminder
      assert row.resource == AshDispatch.Test.Preview.Booking
      assert row.trigger_on == :manual
      assert row.sensitive? == false
      assert %AshDispatch.Channel{} = row.channel
    end

    test "every registered event is listed" do
      ids = Preview.events() |> Enum.map(& &1.event_id) |> Enum.uniq() |> Enum.sort()
      assert ids == ["booking.broken", "booking.confirmed", "booking.reminder"]
    end
  end

  describe "render/3 — sources" do
    test ":sample renders from sample_data/1, and the same seed gives the same letter" do
      assert {:ok, [first]} = Preview.render("booking.confirmed", :sample, seed: 7)
      assert {:ok, [again]} = Preview.render("booking.confirmed", :sample, seed: 7)
      assert %Rendered{error: nil, seed: 7} = first

      assert Map.take(first, [:to, :subject, :html_body, :text_body]) ==
               Map.take(again, [:to, :subject, :html_body, :text_body])

      subjects =
        for seed <- 1..10 do
          {:ok, [letter]} = Preview.render("booking.confirmed", :sample, seed: seed)
          letter.subject
        end

      assert length(Enum.uniq(subjects)) > 1, "the seed changed nothing: #{inspect(subjects)}"
    end

    test ":sample without a seed draws one and says which" do
      assert {:ok, [letter]} = Preview.render("booking.confirmed")
      assert is_integer(letter.seed)

      assert {:ok, [again]} = Preview.render("booking.confirmed", :sample, seed: letter.seed)
      assert again.subject == letter.subject
    end

    test "seeding does not leave the caller's :rand predictable" do
      :rand.seed(:exsss, {1, 2, 3})
      expected = :rand.uniform(1_000_000)

      :rand.seed(:exsss, {1, 2, 3})
      {:ok, _} = Preview.render("booking.confirmed", :sample, seed: 99)
      assert :rand.uniform(1_000_000) == expected
    end

    test "sample_data/0 is the fallback when an event has no sample_data/1" do
      assert {:ok, letters} = Preview.render("booking.reminder", :sample, transport: :email)
      assert Enum.all?(letters, &(&1.to == "guest@example.com"))
    end

    test "{:record, id} reads the record" do
      booking = create_booking!(%{guest_name: "Nils", guest_email: "nils@example.com"})

      assert {:ok, [letter]} = Preview.render("booking.confirmed", {:record, booking.id})
      assert letter.to == "nils@example.com"
      assert letter.html_body =~ "Hi Nils"
      assert letter.recipient_name == "Nils"
    end

    test "{:record, id} with an unknown id errors" do
      assert {:error, message} =
               Preview.render(
                 "booking.confirmed",
                 {:record, "00000000-0000-0000-0000-000000000000"}
               )

      assert message =~ "Failed to load"
    end

    test "a map is the event's data, as given" do
      booking = %AshDispatch.Test.Preview.Booking{
        id: Ash.UUID.generate(),
        reference: "B-MAP",
        guest_name: "Saga",
        guest_email: "saga@example.com"
      }

      assert {:ok, [letter]} = Preview.render("booking.confirmed", %{booking: booking})
      assert letter.subject == "Booking B-MAP confirmed"
      assert letter.seed == nil
    end

    test "an event module works as well as its id" do
      assert {:ok, [_]} =
               Preview.render(AshDispatch.Test.Preview.BookingConfirmed, :sample, seed: 1)
    end

    test "an unknown event errors" do
      assert {:error, message} = Preview.render("no.such.event")
      assert message =~ "no.such.event"
    end
  end

  describe "render/3 — filters and options" do
    test ":transport, :audience and :variant select channels" do
      assert {:ok, [host]} = Preview.render("booking.reminder", :sample, variant: "host")
      assert host.subject =~ "Guest reminder"
      assert host.html_body =~ "Your guest has been reminded"

      assert {:ok, [in_app]} = Preview.render("booking.reminder", :sample, transport: :in_app)
      assert in_app.title == "Reminder sent"
      assert in_app.message == "Reminder for B-SAMPLE"
      assert in_app.html_body == nil

      assert {:ok, []} = Preview.render("booking.reminder", :sample, audience: :admin)
    end

    test "a row from events/0 renders exactly that row" do
      row =
        Enum.find(
          Preview.events(),
          &(&1.event_id == "booking.reminder" and &1.variant == "host")
        )

      assert {:ok, [letter]} = Preview.render(row)
      assert letter.variant == "host"
    end

    test ":recipient_email changes what is shown, not whom it is rendered for" do
      assert {:ok, [letter]} =
               Preview.render("booking.confirmed", :sample,
                 seed: 3,
                 recipient_email: "me@example.com"
               )

      assert letter.to == "me@example.com"
      assert letter.recipient == "me@example.com"
      refute letter.html_body =~ "me@example.com"
    end

    test ":locale is the locale the letter is rendered in" do
      assert {:ok, [letter]} = Preview.render("booking.confirmed", :sample, seed: 1, locale: "sv")
      assert letter.locale == "sv"
    end

    test "the envelope carries sender, reply address, headers and attachments" do
      assert {:ok, [letter]} = Preview.render("booking.confirmed", :sample, seed: 5)

      assert letter.from == {"Bookings", "bookings@example.com"}
      assert letter.reply_to == "host@example.com"
      assert %{"X-Entity-Ref-ID" => "B-" <> _} = letter.headers
      assert [%{filename: "booking.ics", data: "BEGIN:VCALENDAR" <> _}] = letter.attachments
    end
  end

  describe "AshDispatch.EventResolver.sample_data/2" do
    test "passes the seed to sample_data/1" do
      a =
        AshDispatch.EventResolver.sample_data(AshDispatch.Test.Preview.BookingConfirmed, seed: 1)

      assert %{booking: %AshDispatch.Test.Preview.Booking{}} = a
    end

    test "falls back on sample_data/0 through the default sample_data/1" do
      assert %{booking: %{reference: "B-SAMPLE"}} =
               AshDispatch.EventResolver.sample_data(
                 AshDispatch.Test.Preview.BookingReminder,
                 seed: 1
               )
    end
  end
end
