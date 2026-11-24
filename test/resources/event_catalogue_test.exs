defmodule AshDispatch.Resources.EventCatalogueTest do
  @moduledoc """
  The event catalogue as a resource a host can own.

  `AshDispatch.Resources.EmailEvent` is the same idea with three things nailed
  down: policies of `actor_attribute_equals(:super_admin, true)`, a module
  rather than a macro, and every event without an email channel dropped. A
  host whose permission model is not a `super_admin` boolean cannot use it,
  and a host delivering by SMS, Slack or in-app notifications cannot see those
  events in it. This file pins the three answers, and that `EmailEvent` itself
  did not move.
  """
  use AshDispatch.Test.PreviewCase, async: false

  alias AshDispatch.Resources.EmailEvent
  alias AshDispatch.Resources.EventCatalogue
  alias AshDispatch.Test.Preview.Catalogue
  alias AshDispatch.Test.Preview.EmailOnlyCatalogue
  alias AshDispatch.Test.Preview.Librarian
  alias AshDispatch.Test.Preview.OwnPolicyCatalogue

  @moduletag :capture_log

  defp read!(resource, opts) do
    resource |> Ash.Query.for_read(:list) |> Ash.read!(opts)
  end

  defp event(rows, id), do: Enum.find(rows, &(&1.id == id))

  describe "every transport, not only email" do
    test "an event with an in-app channel lists it" do
      rows = read!(Catalogue, authorize?: false)
      reminder = event(rows, "booking.reminder")

      transports = reminder.channels |> Enum.map(& &1.transport) |> Enum.uniq() |> Enum.sort()

      assert transports == [:email, :in_app]
      assert reminder.transports == [:email, :in_app]
    end

    test "an in-app channel carries its in-app content, not an email envelope" do
      rows = read!(Catalogue, authorize?: false)
      reminder = event(rows, "booking.reminder")

      in_app = Enum.find(reminder.channels, &(&1.transport == :in_app))

      assert in_app.title == "Reminder sent"
      assert in_app.message =~ "Reminder for"
      assert in_app.preview_html == nil
    end

    test "an email channel still carries the rendered bodies" do
      rows = read!(Catalogue, authorize?: false)
      reminder = event(rows, "booking.reminder")

      email = Enum.find(reminder.channels, &(&1.transport == :email and is_nil(&1.variant)))

      assert email.subject =~ "See you soon"
      assert email.preview_html
      assert email.preview_text
    end

    test "the counts are of the whole event, whatever the catalogue lists" do
      [reminder] =
        EmailOnlyCatalogue
        |> read!(authorize?: false)
        |> Enum.filter(&(&1.id == "booking.reminder"))

      # Two email channels of three.
      assert reminder.channel_count == 3
      assert reminder.email_channel_count == 2
      assert length(reminder.channels) == 2
    end

    test "previews?: false renders nothing but still names the subject" do
      [reminder] =
        EmailOnlyCatalogue
        |> read!(authorize?: false)
        |> Enum.filter(&(&1.id == "booking.reminder"))

      assert Enum.all?(reminder.channels, &(&1.subject != nil))
      refute Enum.any?(reminder.channels, &Map.has_key?(&1, :preview_html))
    end
  end

  describe "the default policies go through the configured permission_checker" do
    setup do
      previous = Application.fetch_env(:ash_dispatch, :permission_checker)
      Application.put_env(:ash_dispatch, :permission_checker, Librarian)

      on_exit(fn ->
        case previous do
          {:ok, old} -> Application.put_env(:ash_dispatch, :permission_checker, old)
          :error -> Application.delete_env(:ash_dispatch, :permission_checker)
        end
      end)

      :ok
    end

    test "an actor the checker approves reads it" do
      actor = %{permissions: [:view_event_catalogue]}

      assert read!(Catalogue, actor: actor, authorize?: true) != []
    end

    test "an actor the checker does not approve is forbidden, not given an empty list" do
      actor = %{permissions: [:something_else]}

      assert_raise Ash.Error.Forbidden, fn ->
        Catalogue |> Ash.Query.for_read(:list) |> Ash.read!(actor: actor, authorize?: true)
      end
    end

    test "no actor at all is forbidden" do
      assert_raise Ash.Error.Forbidden, fn ->
        Catalogue |> Ash.Query.for_read(:list) |> Ash.read!(authorize?: true)
      end
    end

    test "a worker reading with authorize?: false still gets through" do
      assert read!(Catalogue, authorize?: false) != []
    end
  end

  describe "with no permission_checker configured" do
    setup do
      previous = Application.fetch_env(:ash_dispatch, :permission_checker)
      Application.delete_env(:ash_dispatch, :permission_checker)

      on_exit(fn ->
        case previous do
          {:ok, old} -> Application.put_env(:ash_dispatch, :permission_checker, old)
          :error -> Application.delete_env(:ash_dispatch, :permission_checker)
        end
      end)

      :ok
    end

    test "it is closed — the right direction to fail in for a surface that renders letters" do
      assert_raise Ash.Error.Forbidden, fn ->
        Catalogue
        |> Ash.Query.for_read(:list)
        |> Ash.read!(actor: %{permissions: [:view_event_catalogue]}, authorize?: true)
      end
    end
  end

  describe "policies: :own" do
    test "the host's own bypass opens it" do
      assert read!(OwnPolicyCatalogue, actor: %{librarian: true}, authorize?: true) != []
    end

    test "and closes it for everyone else, with no policy of the library's in the way" do
      assert_raise Ash.Error.Forbidden, fn ->
        OwnPolicyCatalogue
        |> Ash.Query.for_read(:list)
        |> Ash.read!(actor: %{librarian: false}, authorize?: true)
      end
    end

    test "a permission_checker is not consulted at all" do
      # Nothing configured, and the host's actor still gets in: the library
      # declared no policy here.
      refute AshDispatch.Config.permission_checker()
      assert read!(OwnPolicyCatalogue, actor: %{librarian: true}, authorize?: true) != []
    end
  end

  describe ":get" do
    test "answers one event" do
      assert [row] =
               Catalogue
               |> Ash.Query.for_read(:get, %{id: "booking.reminder"})
               |> Ash.read!(authorize?: false)

      assert row.id == "booking.reminder"
    end

    test "answers nothing for an unknown id rather than raising" do
      assert [] =
               Catalogue
               |> Ash.Query.for_read(:get, %{id: "nothing.here"})
               |> Ash.read!(authorize?: false)
    end

    test "respects the catalogue's transport filter" do
      # booking.confirmed is email-only, so both catalogues have it...
      assert [_] =
               EmailOnlyCatalogue
               |> Ash.Query.for_read(:get, %{id: "booking.confirmed"})
               |> Ash.read!(authorize?: false)
    end
  end

  describe "EmailEvent did not move" do
    test "it still lists email events only, with the keys it always had" do
      rows = EmailEvent |> Ash.Query.for_read(:list) |> Ash.read!(authorize?: false)
      reminder = event(rows, "booking.reminder")

      assert Enum.all?(reminder.channels, &(&1.transport == :email))

      assert reminder.channels
             |> hd()
             |> Map.keys()
             |> Enum.sort() == [
               :audience,
               :policy,
               :preview_html,
               :preview_text,
               :subject,
               :time,
               :transport,
               :variant
             ]
    end

    test "it still drops an event with no email channel" do
      # Nothing in these fixtures is in-app only, so the guard is stated
      # directly rather than inferred.
      assert EventCatalogue.rows(transports: [:in_app], previews?: false) != []

      rows = EmailEvent |> Ash.Query.for_read(:list) |> Ash.read!(authorize?: false)
      assert Enum.all?(rows, &(&1.email_channel_count > 0))
    end
  end
end
