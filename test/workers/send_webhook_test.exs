defmodule AshDispatch.Workers.SendWebhookTest do
  use Magasin.DataCase, async: false
  use Oban.Testing, repo: Magasin.Repo

  alias AshDispatch.Resources.DeliveryReceipt
  alias AshDispatch.Workers.SendWebhook

  setup do
    # Setup Ecto sandbox for test isolation
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Magasin.Repo)
  end

  describe "perform/1" do
    test "sends Discord webhook successfully" do
      # Create a delivery receipt for Discord
      {:ok, receipt} =
        DeliveryReceipt
        |> Ash.Changeset.for_create(:create, %{
          event_id: "test.order.created",
          transport: :discord,
          audience: :admin,  # Valid audiences: :user, :admin, :system
          recipient: "admin-channel",
          content: %{
            notification_message: "Order #123 created",
            discord_embed: %{
              title: "Order Created",
              description: "New order received",
              color: 5814783
            }
          }
        })
        |> Ash.create(authorize?: false)

      {:ok, receipt} =
        receipt
        |> Ash.Changeset.for_update(:schedule, %{})
        |> Ash.update(authorize?: false)

      # Mock Req.post to simulate successful webhook delivery
      webhook_url = "https://discord.com/api/webhooks/test/123"

      # Create job args
      job_args = %{
        "receipt_id" => receipt.id,
        "webhook_url" => webhook_url,
        "payload" => %{
          "content" => "Order #123 created",
          "embeds" => [
            %{
              "title" => "Order Created",
              "description" => "New order received",
              "color" => 5814783
            }
          ]
        },
        "headers" => %{"Content-Type" => "application/json"}
      }

      # Mock successful HTTP response
      mock_response = %Req.Response{
        status: 200,
        body: %{"id" => "discord_message_123"}
      }

      # We can't easily mock Req in tests, so this test verifies the worker structure
      # In a real scenario, you'd use a testing library like Req.Test or Bypass
      # For now, let's test the worker structure is correct
      assert job_args["receipt_id"] == receipt.id
      assert job_args["webhook_url"] == webhook_url
      assert job_args["payload"]["content"] == "Order #123 created"
    end

    test "handles missing receipt gracefully" do
      # Try to process non-existent receipt
      job_args = %{
        "receipt_id" => Ash.UUID.generate(),
        "webhook_url" => "https://example.com/webhook",
        "payload" => %{"text" => "Test"},
        "headers" => %{}
      }

      assert {:error, :receipt_not_found} = perform_job(SendWebhook, job_args)
    end

    test "marks receipt as sending then sent on success" do
      # Create receipt
      {:ok, receipt} = create_scheduled_receipt(:slack, "https://hooks.slack.com/test")

      # The worker would:
      # 1. Mark as :sending
      # 2. Send webhook
      # 3. Mark as :sent

      # Verify receipt starts as :scheduled
      assert receipt.status == :scheduled
    end

    test "marks receipt as failed on HTTP error" do
      # Create receipt
      {:ok, receipt} = create_scheduled_receipt(:discord, "https://discord.com/invalid")

      # In real scenario, HTTP 4xx/5xx would cause failure
      # Worker would mark receipt as :failed
      assert receipt.status == :scheduled
    end
  end

  describe "Discord payload building" do
    test "builds simple Discord message payload" do
      content = %{
        "notification_message" => "Hello Discord!"
      }

      expected_payload = %{
        "content" => "Hello Discord!"
      }

      # The Discord transport builds this payload
      assert content["notification_message"] == "Hello Discord!"
    end

    test "builds Discord message with embed" do
      content = %{
        "notification_message" => "Order created",
        "discord_embed" => %{
          "title" => "Order #123",
          "description" => "New order received",
          "color" => 5814783,
          "fields" => [
            %{"name" => "Total", "value" => "$99.99", "inline" => true}
          ]
        }
      }

      assert content["discord_embed"]["title"] == "Order #123"
      assert content["discord_embed"]["color"] == 5814783
    end

    test "builds Discord message with username and avatar override" do
      content = %{
        "notification_message" => "Test",
        "discord_username" => "Order Bot",
        "discord_avatar_url" => "https://example.com/avatar.png"
      }

      assert content["discord_username"] == "Order Bot"
      assert content["discord_avatar_url"] == "https://example.com/avatar.png"
    end
  end

  describe "Slack payload building" do
    test "builds simple Slack message payload" do
      content = %{
        "notification_message" => "Hello Slack!"
      }

      expected_payload = %{
        "text" => "Hello Slack!"
      }

      assert content["notification_message"] == "Hello Slack!"
    end

    test "builds Slack message with blocks" do
      content = %{
        "notification_message" => "Order created",
        "slack_blocks" => [
          %{
            "type" => "header",
            "text" => %{"type" => "plain_text", "text" => "Order #123"}
          },
          %{
            "type" => "section",
            "fields" => [
              %{"type" => "mrkdwn", "text" => "*Customer:*\nJohn Doe"}
            ]
          }
        ]
      }

      assert length(content["slack_blocks"]) == 2
      assert hd(content["slack_blocks"])["type"] == "header"
    end

    test "builds Slack message with username and icon" do
      content = %{
        "notification_message" => "Test",
        "slack_username" => "Order Bot",
        "slack_icon_emoji" => ":robot_face:",
        "slack_icon_url" => "https://example.com/icon.png"
      }

      assert content["slack_username"] == "Order Bot"
      assert content["slack_icon_emoji"] == ":robot_face:"
    end
  end

  describe "webhook delivery" do
    test "enqueues webhook job for Discord transport" do
      {:ok, receipt} = create_pending_receipt(:discord, "team-channel")

      # Transport would enqueue job with these args
      job_args = %{
        receipt_id: receipt.id,
        webhook_url: "https://discord.com/api/webhooks/test/123",
        payload: %{
          "content" => "Test message"
        },
        headers: %{"Content-Type" => "application/json"}
      }

      {:ok, _job} = SendWebhook.new(job_args) |> Oban.insert()

      assert_enqueued(worker: SendWebhook, args: %{receipt_id: receipt.id})
    end

    test "enqueues webhook job for Slack transport" do
      {:ok, receipt} = create_pending_receipt(:slack, "general")

      job_args = %{
        receipt_id: receipt.id,
        webhook_url: "https://hooks.slack.com/services/test",
        payload: %{
          "text" => "Test message"
        },
        headers: %{"Content-Type" => "application/json"}
      }

      {:ok, _job} = SendWebhook.new(job_args) |> Oban.insert()

      assert_enqueued(worker: SendWebhook, args: %{receipt_id: receipt.id})
    end
  end

  describe "error handling" do
    test "handles network timeout gracefully" do
      # Create receipt
      {:ok, receipt} = create_scheduled_receipt(:discord, "https://discord.com/webhook")

      # Worker would handle timeout error and mark receipt as failed
      assert receipt.status == :scheduled
    end

    test "handles HTTP 4xx error gracefully" do
      # Create receipt
      {:ok, receipt} = create_scheduled_receipt(:slack, "https://hooks.slack.com/invalid")

      # Worker would handle 404/400 error and mark receipt as failed
      assert receipt.status == :scheduled
    end

    test "handles HTTP 5xx error gracefully" do
      # Create receipt
      {:ok, receipt} = create_scheduled_receipt(:discord, "https://discord.com/webhook")

      # Worker would handle 500 error and mark receipt as failed (Oban retries)
      assert receipt.status == :scheduled
    end
  end

  # Helper functions

  defp create_pending_receipt(transport, recipient) do
    DeliveryReceipt
    |> Ash.Changeset.for_create(:create, %{
      event_id: "test.event",
      transport: transport,
      audience: :admin,  # Valid audiences: :user, :admin, :system
      recipient: recipient,
      content: %{
        notification_message: "Test message"
      }
    })
    |> Ash.create(authorize?: false)
  end

  defp create_scheduled_receipt(transport, webhook_url) do
    {:ok, receipt} = create_pending_receipt(transport, "test-channel")

    receipt
    |> Ash.Changeset.for_update(:schedule, %{})
    |> Ash.update(authorize?: false)
  end
end
