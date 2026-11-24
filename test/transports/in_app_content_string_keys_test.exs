defmodule AshDispatch.Transports.InAppContentStringKeysTest do
  @moduledoc """
  An in-app notification must carry what the event module put in the receipt's
  content, including after the receipt has been through the database.

  `content` is a JSONB column, so a receipt read back from Postgres has
  `"metadata"` and not `:metadata`. `create_notification_for_receipt/4` read
  only the atom key, so everything an event module adds through
  `extra_content/2` was dropped on the way to the notification, leaving nothing
  to lead from a notification back to what it is about except the idempotency
  key. Refs #50; same defect class as the sender in #64.
  """
  use AshDispatch.Test.InboxCase, async: false

  alias AshDispatch.Channel
  alias AshDispatch.ContentMap
  alias AshDispatch.Context
  alias AshDispatch.Test.TransportReceipt
  alias AshDispatch.Transports.InApp

  @moduletag :capture_log

  @channel %Channel{transport: :in_app, audience: :user}

  # A receipt as Postgres hands it back: every key in `content` is a string,
  # however the dispatcher wrote it.
  defp receipt!(content, user_id) do
    TransportReceipt
    |> Ash.Changeset.for_create(:create, %{
      event_id: "alarm.raised",
      audience: :user,
      transport: :in_app,
      user_id: user_id,
      recipient: "anna@example.com",
      content: content
    })
    |> Ash.create!(authorize?: false)
  end

  defp context, do: %Context{event_id: "alarm.raised", data: %{}}

  defp deliver!(content) do
    user_id = Ash.UUID.generate()

    assert {:ok, _} = InApp.deliver(receipt!(content, user_id), context(), @channel, [])

    assert [notification] = notifications_for(user_id)
    notification
  end

  describe "a receipt read back from JSONB" do
    test "the event's own metadata reaches the notification" do
      notification =
        deliver!(%{
          "title" => "Alarm raised",
          "message" => "Sensor 7 is above its ceiling",
          "notification_type" => "warning",
          "metadata" => %{"alarm_id" => "alarm-1", "source" => "sensor-7"}
        })

      assert notification.metadata["alarm_id"] == "alarm-1"
      assert notification.metadata["source"] == "sensor-7"
    end

    test "the priority is added beside it, not instead of it" do
      notification =
        deliver!(%{
          "title" => "Alarm raised",
          "message" => "Sensor 7 is above its ceiling",
          "notification_type" => "warning",
          "metadata" => %{"alarm_id" => "alarm-1"}
        })

      assert notification.metadata["alarm_id"] == "alarm-1"
      assert ContentMap.get_content(notification.metadata, :priority) == :standard
    end

    test "the metadata reaches the broadcast the client reads" do
      deliver!(%{
        "title" => "Alarm raised",
        "message" => "Sensor 7 is above its ceiling",
        "notification_type" => "warning",
        "metadata" => %{"alarm_id" => "alarm-1"}
      })

      assert Enum.any?(broadcasts(), fn {_topic, "new_notification", payload} ->
               payload.metadata["alarm_id"] == "alarm-1"
             end)
    end

    test "a receipt with no metadata of its own still gets the priority" do
      notification =
        deliver!(%{
          "title" => "Alarm raised",
          "message" => "Sensor 7 is above its ceiling",
          "notification_type" => "warning"
        })

      assert ContentMap.get_content(notification.metadata, :priority) == :standard
    end
  end

  # `retry_from_receipt/1` runs from a receipt that has been stored, so its
  # content has string keys by definition — there is no atom-key case here.
  describe "a retry, which always works from a stored receipt" do
    test "carries the event's metadata and its invalidation keys" do
      user_id = Ash.UUID.generate()

      receipt =
        receipt!(
          %{
            "title" => "Alarm raised",
            "message" => "Sensor 7 is above its ceiling",
            "notification_type" => "warning",
            "metadata" => %{"alarm_id" => "alarm-1"},
            "invalidates" => ["alarms"]
          },
          user_id
        )

      assert :ok = InApp.retry_from_receipt(receipt)

      assert [notification] = notifications_for(user_id)
      assert notification.metadata["alarm_id"] == "alarm-1"

      assert Enum.any?(broadcasts(), fn {_topic, "new_notification", payload} ->
               payload.invalidates == ["alarms"]
             end)
    end
  end

  describe "an in-memory receipt, whose content still has atom keys" do
    test "the event's own metadata reaches the notification" do
      notification =
        deliver!(%{
          title: "Alarm raised",
          message: "Sensor 7 is above its ceiling",
          notification_type: :warning,
          metadata: %{"alarm_id" => "alarm-1"}
        })

      assert notification.metadata["alarm_id"] == "alarm-1"
      assert ContentMap.get_content(notification.metadata, :priority) == :standard
    end
  end
end
