defmodule AshDispatch.Dispatch.ActorTenantTest do
  @moduledoc """
  0.8.8: `Dispatcher.dispatch/4`'s `:actor` and `:tenant`, what the
  preference checker is told, and `recipient_fields` `id:`.

  Until 0.8.8 `:actor` only named who asked for an override, a manual event
  had no tenant at all, the checker was told only the category and the
  audience, and a map recipient had to call its user key `:id` to be linked
  to a user.
  """
  use AshDispatch.Test.MeetingCase, async: false

  alias AshDispatch.Dispatcher
  alias AshDispatch.Event.RecipientExtractor

  defp exclude_actor_on_manual_dispatch! do
    Application.put_env(:ash_dispatch, :exclude_actor_on_manual_dispatch, true)
  end

  describe ":actor on a manual dispatch" do
    test "is kept as context.actor; context.user is still what data says" do
      anna = user("anna")

      assert {:ok, prepared} =
               Dispatcher.prepare("meeting.updated", %{participants: []}, %{}, actor: anna)

      assert prepared.context.actor == anna
      # No user in data, no user module configured: as before 0.8.8.
      assert prepared.context.user == nil
    end

    test "exclude_actor does not leave the actor out by default (unchanged from 0.8.7)" do
      [anna, bo] = [user("anna"), user("bo")]

      assert {:ok, _} = send_updated([anna, bo], actor: anna)

      assert sent_to() == Enum.sort([anna.email, bo.email])
    end

    test "with exclude_actor_on_manual_dispatch: true, exclude_actor leaves the actor out" do
      exclude_actor_on_manual_dispatch!()
      [anna, bo] = [user("anna"), user("bo")]

      assert {:ok, _} = send_updated([anna, bo], actor: anna)

      assert sent_to() == [bo.email]
      assert [%{user_id: user_id}] = receipts("meeting.updated")
      assert user_id == bo.id
    end

    test "the option changes nothing for a system event (no actor)" do
      exclude_actor_on_manual_dispatch!()
      [anna, bo] = [user("anna"), user("bo")]

      assert {:ok, _} = send_updated([anna, bo])

      assert sent_to() == Enum.sort([anna.email, bo.email])
    end

    test "the ManualTrigger :trigger action's actor is the dispatch's actor" do
      exclude_actor_on_manual_dispatch!()
      [anna, bo] = [user("anna"), user("bo")]

      meeting =
        AshDispatch.Test.Meeting.Meeting
        |> Ash.Changeset.for_create(:create, %{title: "Review"})
        |> Ash.create!(authorize?: false)

      assert {:ok, _} =
               AshDispatch.Test.Meeting.ManualTrigger
               |> Ash.Changeset.for_create(
                 :trigger,
                 %{
                   event_id: "meeting.updated",
                   context_data: %{
                     "meeting_id" => meeting.id,
                     "participants" => [
                       %{"id" => anna.id, "email" => anna.email},
                       %{"id" => bo.id, "email" => bo.email}
                     ]
                   }
                 },
                 actor: anna,
                 tenant: "org_1"
               )
               |> Ash.create(authorize?: false)

      assert sent_to() == [bo.email]
      assert [%{opts: opts}] = checks()
      assert opts[:tenant] == "org_1"
    end
  end

  describe "an action-triggered event" do
    setup do
      [anna, bo] = [user("anna"), user("bo")]
      Application.put_env(:ash_dispatch, :test_meeting_participants, [anna, bo])

      meeting =
        AshDispatch.Test.Meeting.Meeting
        |> Ash.Changeset.for_create(:create, %{title: "Planning"})
        |> Ash.create!(authorize?: false)

      %{anna: anna, bo: bo, meeting: meeting}
    end

    test "leaves its actor out, as it always has, and hands its tenant to the checker",
         %{anna: anna, bo: bo, meeting: meeting} do
      meeting
      |> Ash.Changeset.for_update(:rename, %{title: "Review"}, actor: anna, tenant: "org_1")
      |> Ash.update!(authorize?: false)

      assert sent_to() == [bo.email]
      assert [%{user_id: user_id, opts: opts}] = checks()
      assert user_id == bo.id
      assert opts[:tenant] == "org_1"
    end
  end

  describe "the preference checker's opts" do
    test "carry the tenant, the recipient and the audience" do
      anna = user("anna")

      assert {:ok, _} = send_updated([anna], tenant: "org_1")

      assert [check] = checks()
      assert check.user_id == anna.id
      assert check.event_id == "meeting.updated"
      assert check.transport == :email
      assert check.opts[:tenant] == "org_1"
      assert check.opts[:recipient] == anna
      assert check.opts[:audience] == :user
      assert check.opts[:event_id] == "meeting.updated"
    end

    test "tenant is nil without one, and the recipient is each receipt's own" do
      [anna, bo] = [user("anna"), user("bo")]

      assert {:ok, _} = send_updated([anna, bo])

      checks = checks()
      assert Enum.all?(checks, &is_nil(&1.opts[:tenant]))

      assert Enum.map(checks, &{&1.user_id, &1.opts[:recipient]}) |> Enum.sort() ==
               Enum.sort([{anna.id, anna}, {bo.id, bo}])
    end

    test "allows_user?/4 passes tenant and recipient on, nil when not given" do
      assert AshDispatch.UserPreference.allows_user?("u1", "meeting.updated", :email,
               tenant: "org_1",
               recipient: %{id: "u1"}
             )

      assert [%{opts: opts}] = checks()
      assert opts[:tenant] == "org_1"
      assert opts[:recipient] == %{id: "u1"}

      assert AshDispatch.UserPreference.allows_user?("u1", "meeting.updated", :email, [])
      assert [%{opts: opts}] = checks()
      assert Keyword.has_key?(opts, :tenant) and is_nil(opts[:tenant])
      assert Keyword.has_key?(opts, :recipient) and is_nil(opts[:recipient])
    end
  end

  describe "recipient_fields id:" do
    setup do
      Application.put_env(:ash_dispatch, :recipient_fields,
        email: [identifier: :email],
        audiences: [user: [id: :user_id]]
      )

      :ok
    end

    test "a map recipient's user id comes from the configured key" do
      contact = %{user_id: Ash.UUID.generate(), email: "contact@example.com"}

      assert {:ok, _} = send_updated([contact])

      assert [receipt] = receipts("meeting.updated")
      assert receipt.user_id == contact.user_id
      assert [%{user_id: user_id}] = checks()
      assert user_id == contact.user_id
    end

    test "exclude_actor compares the configured id" do
      exclude_actor_on_manual_dispatch!()
      actor = %{id: Ash.UUID.generate()}
      own = %{user_id: actor.id, email: "me@example.com"}
      other = %{user_id: Ash.UUID.generate(), email: "other@example.com"}

      assert {:ok, _} = send_updated([own, other], actor: actor)

      assert sent_to() == ["other@example.com"]
    end

    test "a recipient without one is sent to, with a receipt without a user" do
      assert {:ok, _} = send_updated([%{email: "guest@example.com"}])

      assert sent_to() == ["guest@example.com"]
      assert [%{user_id: nil}] = receipts("meeting.updated")
      # No user, nothing to ask.
      assert checks() == []
    end
  end

  describe "recipient_fields without id:" do
    test "the user id is the recipient's :id, as before" do
      anna = Map.put(user("anna"), :user_id, Ash.UUID.generate())

      assert {:ok, _} = send_updated([anna])

      assert [receipt] = receipts("meeting.updated")
      assert receipt.user_id == anna.id
    end
  end

  describe "RecipientExtractor.extract_user_id/4" do
    test "defaults to :id, for structs and maps" do
      assert RecipientExtractor.extract_user_id(%{id: "u1"}, :email, :user) == "u1"
      assert RecipientExtractor.extract_user_id(%URI{}, :email, :user) == nil
      assert RecipientExtractor.extract_user_id(nil, :email, :user) == nil
    end

    test "the event's own recipient config wins" do
      assert RecipientExtractor.extract_user_id(
               %{id: "wrong", account: "right"},
               :email,
               :user,
               recipient: [email: [id: :account]]
             ) == "right"
    end

    test "per transport, and per audience and transport" do
      Application.put_env(:ash_dispatch, :recipient_fields,
        email: [identifier: :email, id: :member_id],
        audiences: [admin: [email: [id: :account_id]]]
      )

      recipient = %{id: "id", member_id: "member", account_id: "account"}

      assert RecipientExtractor.extract_user_id(recipient, :email, :user) == "member"
      assert RecipientExtractor.extract_user_id(recipient, :email, :admin) == "account"
      assert RecipientExtractor.extract_user_id(recipient, :sms, :user) == "id"
    end

    test "an audience given in the atom shorthand does not raise" do
      Application.put_env(:ash_dispatch, :recipient_fields, audiences: [user: :email])

      assert RecipientExtractor.extract_user_id(%{id: "u1"}, :email, :user) == "u1"
    end
  end
end
