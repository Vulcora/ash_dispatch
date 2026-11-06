defmodule AshDispatch.Helpers.NotificationLoaderMarkAllTest do
  @moduledoc """
  `NotificationLoader.mark_all_as_read/2` dropped its options, so the action
  ran without an actor and the notification resource's policy (`user_id` must
  be the actor's) refused every call. Fixed in 0.8.8.
  """
  use ExUnit.Case, async: false

  alias AshDispatch.Helpers.NotificationLoader
  alias AshDispatch.Test.MarkAll.{Notification, Repo}

  defmodule StubNotification do
    @moduledoc false
    def mark_all_as_read(user_id, opts) do
      send(self(), {:mark_all_as_read, user_id, opts})
      {:ok, %{success: true}}
    end
  end

  defp with_notification_resource(resource) do
    previous = Application.fetch_env(:ash_dispatch, :notification_resource)
    Application.put_env(:ash_dispatch, :notification_resource, resource)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ash_dispatch, :notification_resource, value)
        :error -> Application.delete_env(:ash_dispatch, :notification_resource)
      end
    end)
  end

  test "passes :actor and :authorize? on to the action, and nothing else" do
    with_notification_resource(StubNotification)
    actor = %{id: "u1"}

    assert {:ok, %{success: true}} =
             NotificationLoader.mark_all_as_read("u1",
               actor: actor,
               authorize?: true,
               unrelated: "ignored"
             )

    assert_received {:mark_all_as_read, "u1", opts}
    assert Enum.sort(opts) == Enum.sort(actor: actor, authorize?: true)
  end

  describe "against Notification.Base on Postgres" do
    @describetag :postgres

    setup do
      # one connection, so the temporary table is visible to every query
      start_supervised!(
        {Repo, url: System.fetch_env!("ASH_DISPATCH_TEST_DATABASE_URL"), pool_size: 1}
      )

      Repo.query!("""
      create temporary table mark_all_test_notifications (
        id uuid primary key,
        user_id uuid not null,
        type text not null,
        title text not null,
        message text not null,
        metadata jsonb not null default '{}',
        action_label text,
        action_url text,
        source text,
        occurred_at timestamp not null,
        read boolean not null default false,
        read_at timestamp,
        event_id text,
        idempotency_key text,
        category text,
        tenant text,
        seen_at timestamp,
        archived_at timestamp,
        inserted_at timestamp not null,
        updated_at timestamp not null
      )
      """)

      with_notification_resource(Notification)

      anna = %{id: Ash.UUID.generate()}
      bo = %{id: Ash.UUID.generate()}

      for user <- [anna, anna, bo] do
        Notification
        |> Ash.Changeset.for_create(:create, %{user_id: user.id, title: "t", message: "m"})
        |> Ash.create!(authorize?: false)
      end

      %{anna: anna, bo: bo}
    end

    defp unread(user) do
      Notification
      |> Ash.read!(authorize?: false)
      |> Enum.count(&(&1.user_id == user.id and not &1.read))
    end

    test "marks the actor's own notifications as read", %{anna: anna, bo: bo} do
      assert {:ok, _} = NotificationLoader.mark_all_as_read(anna.id, actor: anna)

      assert unread(anna) == 0
      assert unread(bo) == 1
    end

    test "is still forbidden for someone else's", %{anna: anna, bo: bo} do
      assert {:error, %Ash.Error.Forbidden{}} =
               NotificationLoader.mark_all_as_read(bo.id, actor: anna)

      assert unread(bo) == 1
    end
  end
end
