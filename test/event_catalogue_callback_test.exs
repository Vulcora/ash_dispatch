defmodule AshDispatch.EventCatalogueCallbackTest do
  @moduledoc """
  `c:AshDispatch.Event.catalogue/0`: what an event IS, in words.

  `Preview.events/0` answers an event id, a transport, an audience and a
  variant — the right answer for a test, the wrong one for a page where
  somebody picks a letter to send. Two hosts wrote a parallel list beside the
  catalogue for exactly that, kept in step with the DSL by hand.

  The callback is optional and deliberately not defaulted by
  `use AshDispatch.Event`, so an event that does not describe itself is listed
  exactly as it was. That half is pinned here as hard as the new half.
  """
  use AshDispatch.Test.PreviewCase, async: false

  alias AshDispatch.Event.Catalogue
  alias AshDispatch.EventResolver
  alias AshDispatch.Preview
  alias AshDispatch.Test.Preview.BookingConfirmed
  alias AshDispatch.Test.Preview.BookingReminder

  @moduletag :capture_log

  describe "Catalogue.new/1" do
    test "takes a map" do
      assert %Catalogue{name: "A", group: "G"} = Catalogue.new(%{name: "A", group: "G"})
    end

    test "takes a keyword list" do
      assert %Catalogue{name: "A"} = Catalogue.new(name: "A")
    end

    test "takes string keys, for a list that came from JSON" do
      assert %Catalogue{name: "A", instruction: "I"} =
               Catalogue.new(%{"name" => "A", "instruction" => "I"})
    end

    test "says a non-string field as a string rather than dropping it" do
      assert %Catalogue{group: "bookings"} = Catalogue.new(%{group: :bookings})
    end

    test "keeps everything else under meta" do
      assert %Catalogue{name: "A", meta: %{icon: "bell", order: 3}} =
               Catalogue.new(%{name: "A", icon: "bell", order: 3})
    end

    test "nothing in it is nothing: the same as an event that did not answer" do
      assert Catalogue.new(%{}) == nil
      assert Catalogue.new([]) == nil
      assert Catalogue.new(%{name: nil, description: ""}) == nil
    end

    test "an answer that is not a map or keyword list is nil, not a crash" do
      assert Catalogue.new("Booking reminder") == nil
      assert Catalogue.new(nil) == nil
      assert Catalogue.new([:a, :b]) == nil
    end

    test "passes a struct through" do
      catalogue = %Catalogue{name: "A"}
      assert Catalogue.new(catalogue) == catalogue
    end
  end

  describe "EventResolver.catalogue/1" do
    test "answers what the event declared" do
      assert %Catalogue{} = catalogue = EventResolver.catalogue(BookingReminder)

      assert catalogue.name == "Booking reminder"
      assert catalogue.description =~ "day before"
      assert catalogue.trigger =~ "24 hours"
      assert catalogue.audience =~ "guest"
      assert catalogue.group == "Bookings"
      assert catalogue.instruction =~ "by hand"
      assert catalogue.meta == %{icon: "bell"}
    end

    test "nil for an event that does not describe itself" do
      refute function_exported?(BookingConfirmed, :catalogue, 0)
      assert EventResolver.catalogue(BookingConfirmed) == nil
    end

    test "nil for a module that is not an event at all" do
      assert EventResolver.catalogue(Enum) == nil
    end

    test "a callback that raises costs the catalogue, not the catalogue page" do
      defmodule Raising do
        @moduledoc false
        def catalogue, do: raise("no")
      end

      assert EventResolver.catalogue(Raising) == nil
    end
  end

  describe "Preview.events/0" do
    test "surfaces the catalogue on every row of the event" do
      rows = Enum.filter(Preview.events(), &(&1.event_id == "booking.reminder"))

      assert length(rows) == 3
      assert Enum.all?(rows, &(&1.catalogue.name == "Booking reminder"))
      assert Enum.all?(rows, &(&1.catalogue.group == "Bookings"))
    end

    test "an event without one gets nil there, and the row it got before" do
      [row] = Enum.filter(Preview.events(), &(&1.event_id == "booking.confirmed"))

      assert row.catalogue == nil

      # Everything the row always carried is still exactly what it was.
      assert row.event_id == "booking.confirmed"
      assert row.module == BookingConfirmed
      assert row.transport == :email
      assert row.audience == :user
      assert row.variant == nil
      assert row.trigger_on == :create
      assert row.locales == []
      assert row.sensitive? == false
      assert %AshDispatch.Channel{} = row.channel
    end

    test "a row is still usable as a filter for render/3" do
      [row] = Enum.filter(Preview.events(), &(&1.event_id == "booking.confirmed"))

      assert {:ok, [letter]} = Preview.render(row, :sample, seed: 0)
      assert letter.subject
    end
  end

  describe "the catalogue resource" do
    test "flattens it onto the row" do
      [row] =
        AshDispatch.Test.Preview.Catalogue
        |> Ash.Query.for_read(:get, %{id: "booking.reminder"})
        |> Ash.read!(authorize?: false)

      assert row.name == "Booking reminder"
      assert row.description =~ "day before"
      assert row.trigger =~ "24 hours"
      assert row.audience_description =~ "guest"
      assert row.group == "Bookings"
      assert row.instruction =~ "by hand"
      assert row.catalogue_meta == %{icon: "bell"}
    end

    test "and leaves it nil for an event that says nothing" do
      [row] =
        AshDispatch.Test.Preview.Catalogue
        |> Ash.Query.for_read(:get, %{id: "booking.confirmed"})
        |> Ash.read!(authorize?: false)

      assert row.name == nil
      assert row.group == nil
      assert row.catalogue_meta == %{}
      # Still a complete row.
      assert row.id == "booking.confirmed"
      assert row.channels != []
    end
  end
end
