defmodule AshDispatch.Inbox.PreferenceResourceTest do
  @moduledoc """
  `AshDispatch.Resources.Preference.Base` read by
  `AshDispatch.UserPreference.Resource`: the person beats the tenant, the
  tenant beats the event, a mandatory event is never gated — and a fan-out
  costs one query, not one per recipient.
  """
  use AshDispatch.Test.InboxCase, async: false

  alias AshDispatch.UserPreference
  alias AshDispatch.UserPreference.Resource

  defmodule AllowAndReport do
    @moduledoc false
    # A permission checker that allows and reports the opts it was given.
    def match?(_actor, _context, opts) do
      send(self(), {:permission, opts})
      true
    end
  end

  defp delivered?(user, event \\ :updated) do
    notifications_for(user.id) |> Enum.any?(&(&1.event_id == "meeting.#{event}"))
  end

  defp preference_reads(acc \\ 0) do
    receive do
      {:preference_read, _action} -> preference_reads(acc + 1)
    after
      0 -> acc
    end
  end

  describe "precedence" do
    test "nothing said: the event's default (on)" do
      anna = user("anna")
      assert {:ok, _} = send_event(:updated, [anna], tenant: "org_1")
      assert delivered?(anna)
    end

    test "the tenant's default switches it off for everyone in the tenant" do
      [anna, bo] = [user("anna"), user("bo")]

      put_preference!(%{
        tenant: "org_1",
        category: "meetings",
        transport: :in_app,
        enabled: false
      })

      assert {:ok, _} = send_event(:updated, [anna, bo], tenant: "org_1")

      refute delivered?(anna)
      refute delivered?(bo)
      assert Enum.all?(receipts("meeting.updated"), &(&1.error_message == "user_opted_out"))
    end

    test "the tenant's default stays in its tenant" do
      anna = user("anna")

      put_preference!(%{
        tenant: "org_1",
        category: "meetings",
        transport: :in_app,
        enabled: false
      })

      assert {:ok, _} = send_event(:updated, [anna], tenant: "org_2")
      assert delivered?(anna)
    end

    test "the person's row beats the tenant's" do
      [anna, bo] = [user("anna"), user("bo")]

      put_preference!(%{
        tenant: "org_1",
        category: "meetings",
        transport: :in_app,
        enabled: false
      })

      put_preference!(%{
        tenant: "org_1",
        user_id: anna.id,
        event_id: "meeting.updated",
        transport: :in_app,
        enabled: true
      })

      assert {:ok, _} = send_event(:updated, [anna, bo], tenant: "org_1")

      assert delivered?(anna)
      refute delivered?(bo)
    end

    test "a row for the event beats one for its category, at the same level" do
      anna = user("anna")

      put_preference!(%{
        user_id: anna.id,
        category: "meetings",
        transport: :in_app,
        enabled: true
      })

      put_preference!(%{
        user_id: anna.id,
        event_id: "meeting.updated",
        transport: :in_app,
        enabled: false
      })

      assert {:ok, _} = send_event(:updated, [anna])
      refute delivered?(anna)
    end

    test "a row is per transport" do
      anna = user("anna")

      put_preference!(%{
        user_id: anna.id,
        category: "meetings",
        transport: :email,
        enabled: false
      })

      assert {:ok, _} = send_event(:updated, [anna])
      assert delivered?(anna)
    end

    test "the event's own default: metadata preference_default" do
      assert Resource.resolve([], "u", "meeting.starting_soon", "reminders", :email, false) ==
               {false, :event}

      opts = [category: :reminders, audience: :user, tenant: nil, event_default: false]

      refute UserPreference.allows_user?(
               Ash.UUID.generate(),
               "meeting.starting_soon",
               :email,
               opts
             )
    end
  end

  describe "mandatory events (user_configurable: false)" do
    test "are delivered whatever the person said" do
      anna = user("anna")

      put_preference!(%{
        user_id: anna.id,
        event_id: "meeting.cancelled",
        transport: :in_app,
        enabled: false
      })

      put_preference!(%{
        user_id: anna.id,
        category: "meetings",
        transport: :in_app,
        enabled: false
      })

      assert {:ok, _} = send_event(:cancelled, [anna])
      assert delivered?(anna, :cancelled)
    end

    test "are never gated, by any checker" do
      Application.put_env(:ash_dispatch, :user_preference, AshDispatch.Test.Preview.DenyAll)
      anna = user("anna")

      assert {:ok, _} = send_event(:cancelled, [anna])
      assert delivered?(anna, :cancelled)

      assert {:ok, _} = send_event(:updated, [anna])
      refute delivered?(anna, :updated)
    end

    test "allows_user?/4 looks it up when not told" do
      Application.put_env(:ash_dispatch, :user_preference, AshDispatch.Test.Preview.DenyAll)

      assert UserPreference.allows_user?(Ash.UUID.generate(), "meeting.cancelled", :in_app)
      refute UserPreference.allows_user?(Ash.UUID.generate(), "meeting.updated", :in_app)
    end
  end

  describe "one query per dispatch" do
    test "a fan-out to many recipients reads the preferences once" do
      people = for i <- 1..5, do: user("p#{i}")
      [first | _] = people

      put_preference!(%{
        tenant: "org_1",
        user_id: first.id,
        category: "meetings",
        transport: :in_app,
        enabled: false
      })

      _ = preference_reads()

      assert {:ok, _} = send_event(:updated, people, tenant: "org_1")

      assert preference_reads() == 1
      refute delivered?(first)
      assert Enum.count(people, &delivered?/1) == 4
    end

    test "two transports to the same people still read once" do
      people = for i <- 1..3, do: user("p#{i}")
      _ = preference_reads()

      # The email channel cannot render here (no templates); it still passes
      # the gate, which is what this counts.
      _ =
        send_event(:starting_soon, people,
          channels: [%{transport: :in_app}, %{transport: :email}]
        )

      assert preference_reads() == 1
    end

    test "outside a dispatch each question reads for itself" do
      _ = preference_reads()
      opts = [category: :meetings, audience: :user, tenant: nil]

      assert UserPreference.allows_user?(Ash.UUID.generate(), "meeting.updated", :in_app, opts)
      assert UserPreference.allows_user?(Ash.UUID.generate(), "meeting.updated", :in_app, opts)

      assert preference_reads() == 2
    end
  end

  describe "the checker's opts (c)" do
    defmodule Capture do
      @moduledoc false
      @behaviour AshDispatch.UserPreference

      @impl true
      def user_allows?(user_id, event_id, transport, opts) do
        send(
          Application.get_env(:ash_dispatch, :capture_pid),
          {:asked, user_id, event_id, transport, opts}
        )

        true
      end
    end

    test "carry tenant, recipient and audience" do
      Application.put_env(:ash_dispatch, :user_preference, Capture)
      anna = user("anna")

      assert {:ok, _} = send_event(:updated, [anna], tenant: "org_1")

      assert_received {:asked, user_id, "meeting.updated", :in_app, opts}
      assert user_id == anna.id
      assert opts[:tenant] == "org_1"
      assert opts[:recipient] == anna
      assert opts[:audience] == :user
      assert opts[:category] == :meetings
      assert opts[:event_default] == true
    end
  end

  describe "configurable_events/1" do
    test "lists the gated events with category, transports, defaults and whether they can be switched" do
      events = Resource.configurable_events()

      assert %{
               id: "meeting.updated",
               category: "meetings",
               transports: [:in_app, :email],
               default: %{in_app: true, email: true},
               configurable: true
             } in events

      assert %{id: "meeting.cancelled", configurable: false, transports: [:in_app]} =
               Enum.find(events, &(&1.id == "meeting.cancelled"))

      assert %{default: %{in_app: true, email: false}} =
               Enum.find(events, &(&1.id == "meeting.starting_soon"))

      # Admin-only: never gated, so never offered.
      refute Enum.any?(events, &(&1.id == "meeting.flagged"))

      refute Enum.any?(
               Resource.configurable_events(configurable_only: true),
               &(&1.id == "meeting.cancelled")
             )
    end
  end

  describe "settings/3, put/3 and clear/2" do
    test "show the answer, where it comes from and what reset goes back to" do
      anna = user("anna")

      {:ok, _} =
        Resource.put(
          %{tenant: "org_1", category: "meetings", transport: :email},
          false,
          authorize?: false
        )

      {:ok, _} =
        Resource.put(
          %{tenant: "org_1", user_id: anna.id, event_id: "meeting.updated", transport: :email},
          true,
          actor: anna
        )

      settings = Resource.settings(anna.id, "org_1")

      find = fn event, transport ->
        Enum.find(settings, &(&1.event_id == event and &1.transport == transport))
      end

      assert %{enabled: true, source: :user, tenant_default: false, configurable: true} =
               find.("meeting.updated", :email)

      assert %{enabled: true, source: :event} = find.("meeting.updated", :in_app)
      assert %{enabled: false, source: :event} = find.("meeting.starting_soon", :email)
      assert %{enabled: true, configurable: false} = find.("meeting.cancelled", :in_app)

      # Reset: back to the tenant's default.
      assert :ok =
               Resource.clear(
                 %{
                   tenant: "org_1",
                   user_id: anna.id,
                   event_id: "meeting.updated",
                   transport: :email
                 },
                 actor: anna
               )

      assert %{enabled: false, source: :tenant} =
               Enum.find(
                 Resource.settings(anna.id, "org_1"),
                 &(&1.event_id == "meeting.updated" and &1.transport == :email)
               )
    end

    test "put/3 upserts: one row per scope" do
      anna = user("anna")
      scope = %{user_id: anna.id, event_id: "meeting.updated", transport: :email}

      {:ok, _} = Resource.put(scope, false, actor: anna)
      {:ok, _} = Resource.put(scope, true, actor: anna)

      assert [%{enabled: true}] = Ash.read!(Preference, authorize?: false)
    end

    test "a row needs exactly one of event_id and category" do
      assert {:error, _} =
               Preference
               |> Ash.Changeset.for_create(:set, %{transport: :email, enabled: false})
               |> Ash.create(authorize?: false)

      assert {:error, _} =
               Preference
               |> Ash.Changeset.for_create(:set, %{
                 transport: :email,
                 enabled: false,
                 event_id: "meeting.updated",
                 category: "meetings"
               })
               |> Ash.create(authorize?: false)
    end
  end

  describe "policies" do
    test "a person writes their own rows, not anyone else's" do
      [anna, bo] = [user("anna"), user("bo")]

      assert {:ok, _} =
               Resource.put(%{user_id: anna.id, category: "meetings", transport: :email}, false,
                 actor: anna
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               Resource.put(%{user_id: bo.id, category: "meetings", transport: :email}, false,
                 actor: anna
               )
    end

    test "a tenant default needs the permission" do
      anna = user("anna")

      assert {:error, %Ash.Error.Forbidden{}} =
               Resource.put(%{tenant: "org_1", category: "meetings", transport: :email}, false,
                 actor: anna
               )
    end

    test "a tenant default is written only in the action's tenant, and the checker is told which" do
      Application.put_env(:ash_dispatch, :permission_checker, AllowAndReport)
      on_exit(fn -> Application.delete_env(:ash_dispatch, :permission_checker) end)
      anna = user("anna")

      set = fn attrs, tenant ->
        Preference
        |> Ash.Changeset.for_create(:set, attrs, actor: anna, tenant: tenant)
        |> Ash.create()
      end

      row = %{tenant: "org_2", category: "meetings", transport: :email, enabled: false}

      assert {:error, %Ash.Error.Forbidden{}} = set.(row, "org_1")
      assert {:ok, _} = set.(row, "org_2")
      assert_received {:permission, opts}
      assert opts[:permission] == :manage_notification_preferences
      assert opts[:tenant] == "org_2"
    end

    test "a person reads their own rows and the defaults, not other people's" do
      [anna, bo] = [user("anna"), user("bo")]
      put_preference!(%{tenant: "org_1", category: "meetings", transport: :email, enabled: false})
      put_preference!(%{user_id: anna.id, category: "meetings", transport: :email, enabled: true})
      put_preference!(%{user_id: bo.id, category: "meetings", transport: :email, enabled: true})

      rows = Ash.read!(Preference, actor: anna)
      assert Enum.sort(Enum.map(rows, & &1.user_id)) == Enum.sort([nil, anna.id])
    end
  end
end
