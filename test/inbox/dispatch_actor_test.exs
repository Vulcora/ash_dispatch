defmodule AshDispatch.Inbox.DispatchActorTest do
  @moduledoc """
  `Dispatcher.dispatch/4`'s `:actor` and `:tenant` as 0.9.0 stores them, and
  `recipient_fields` `id:`.

  0.8.8 kept the actor as `context.actor` and left it out of `exclude_actor`
  channels only on request. 0.9.0 makes that the default and stores the
  actor's id on every receipt (`actor_id`); the tenant and the event's
  category are filed on the in-app notification.
  """
  use AshDispatch.Test.InboxCase, async: false

  describe ":actor" do
    test "exclude_actor leaves the actor out of a manual event by default" do
      [anna, bo] = [user("anna"), user("bo")]

      assert {:ok, _} = send_event(:updated, [anna, bo], actor: anna)

      assert notifications_for(anna.id) == []
      assert [notification] = notifications_for(bo.id)
      assert notification.title == "meeting.updated: Planning"
    end

    test "the actor's id is on every receipt" do
      [anna, bo, cecilia] = [user("anna"), user("bo"), user("cecilia")]

      assert {:ok, _} = send_event(:updated, [anna, bo, cecilia], actor: anna)

      receipts = receipts("meeting.updated")
      assert Enum.map(receipts, & &1.user_id) |> Enum.sort() == Enum.sort([bo.id, cecilia.id])
      assert Enum.all?(receipts, &(&1.actor_id == anna.id))
    end

    test "without it, the user found in data is excluded and recorded (unchanged)" do
      [anna, bo] = [user("anna"), user("bo")]

      # The lookup in data only runs with a user module configured.
      previous = Application.fetch_env(:ash_dispatch, :user_module)
      Application.put_env(:ash_dispatch, :user_module, AshDispatch.Test.Setup.User)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:ash_dispatch, :user_module, value)
          :error -> Application.delete_env(:ash_dispatch, :user_module)
        end
      end)

      # `data.user` as a bare map: the shape manual pipelines pass.
      assert {:ok, _} = send_event(:updated, [anna, bo], data: %{user: %{id: anna.id}})

      assert notifications_for(anna.id) == []
      assert [_] = notifications_for(bo.id)
      assert Enum.all?(receipts("meeting.updated"), &(&1.actor_id == anna.id))
    end

    test "a system event has no actor: everyone is reached, actor_id is nil" do
      [anna, bo] = [user("anna"), user("bo")]

      assert {:ok, _} = send_event(:updated, [anna, bo])

      assert [_] = notifications_for(anna.id)
      assert [_] = notifications_for(bo.id)
      assert Enum.all?(receipts("meeting.updated"), &is_nil(&1.actor_id))
    end
  end

  describe ":tenant" do
    test "is stored on the in-app notification, with the event's category" do
      anna = user("anna")

      assert {:ok, _} = send_event(:updated, [anna], tenant: "org_1")

      assert [notification] = notifications_for(anna.id)
      assert notification.tenant == "org_1"
      assert notification.category == "meetings"
    end

    test "a record as tenant is stored by its id" do
      anna = user("anna")

      assert {:ok, _} = send_event(:updated, [anna], tenant: %{id: "org_2"})

      assert [%{tenant: "org_2"}] = notifications_for(anna.id)
    end
  end

  describe "recipient_fields id:" do
    setup do
      fields = Application.fetch_env!(:ash_dispatch, :recipient_fields)

      Application.put_env(
        :ash_dispatch,
        :recipient_fields,
        Keyword.put(fields, :audiences, user: [id: :user_id])
      )

      :ok
    end

    test "a map recipient's user id comes from the configured key" do
      contact = %{user_id: Ash.UUID.generate(), email: "contact@example.com"}

      assert {:ok, _} = send_event(:updated, [contact])

      assert [receipt] = receipts("meeting.updated")
      assert receipt.user_id == contact.user_id
      assert [_] = notifications_for(contact.user_id)
    end

    test "exclude_actor compares the configured id" do
      actor = %{id: Ash.UUID.generate()}
      own = %{user_id: actor.id, email: "me@example.com"}
      other = %{user_id: Ash.UUID.generate(), email: "other@example.com"}

      assert {:ok, _} = send_event(:updated, [own, other], actor: actor)

      assert [receipt] = receipts("meeting.updated")
      assert receipt.user_id == other.user_id
    end

    test "a recipient without one gets a receipt without a user" do
      external = %{email: "guest@example.com"}

      # in-app needs a user: the receipt exists and is skipped, nothing raises
      assert {:ok, _} = send_event(:updated, [external])
      assert [%{user_id: nil, status: :skipped}] = receipts("meeting.updated")
    end
  end

  describe "RecipientExtractor.extract_user_id/4" do
    alias AshDispatch.Event.RecipientExtractor

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
  end

  describe "the ManualTrigger :trigger action" do
    test "its actor is excluded and recorded, its tenant reaches the notification" do
      [anna, bo] = [user("anna"), user("bo")]

      meeting =
        AshDispatch.Test.Inbox.Meeting
        |> Ash.Changeset.for_create(:create, %{title: "Review"})
        |> Ash.create!(authorize?: false)

      assert {:ok, _} =
               AshDispatch.Test.Inbox.ManualTrigger
               |> Ash.Changeset.for_create(
                 :trigger,
                 %{
                   event_id: "meeting.updated",
                   transport: :in_app,
                   audience: :user,
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

      assert notifications_for(anna.id) == []
      assert [notification] = notifications_for(bo.id)
      assert notification.title == "meeting.updated: Review"
      assert notification.tenant == "org_1"
      assert [%{actor_id: actor_id}] = receipts("meeting.updated")
      assert actor_id == anna.id
    end
  end
end
