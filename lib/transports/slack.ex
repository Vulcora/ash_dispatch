defmodule AshDispatch.Transports.Slack do
  @moduledoc """
  Slack webhook transport.

  Sends messages to Slack channels via webhooks (async via Oban).

  ## Configuration

  Requires `webhook_url` in channel metadata or via callback:

      # Inline configuration
      event :order_created,
        channels: [
          [
            transport: :slack,
            audience: :team,
            metadata: [
              webhook_url: "https://hooks.slack.com/services/..."
            ]
          ]
        ]

      # Or via callback module
      def channels(context) do
        [
          %Channel{
            transport: :slack,
            audience: :team,
            metadata: %{
              webhook_url: get_slack_webhook_url(:orders)
            }
          }
        ]
      end

  ## Content

  Slack messages support:
  - `notification_message` - Simple text content (supports Slack mrkdwn)
  - `slack_blocks` - Block Kit layout blocks for rich formatting
  - `slack_attachments` - Legacy attachment format
  - `slack_username` - Override bot username
  - `slack_icon_emoji` - Override bot icon with emoji
  - `slack_icon_url` - Override bot icon with image URL

  Example with blocks:

      content: [
        notification_message: "New order received!",
        slack_blocks: [
          %{
            type: "header",
            text: %{type: "plain_text", text: "Order {{id}} Created"}
          },
          %{
            type: "section",
            fields: [
              %{type: "mrkdwn", text: "*Customer:*\\n{{user.name}}"},
              %{type: "mrkdwn", text: "*Total:*\\n${{total}}"}
            ]
          }
        ]
      ]

  ## Slack Message Formatting

  Slack uses mrkdwn (markdown-like) formatting:
  - `*bold*` - Bold text
  - `_italic_` - Italic text
  - `~strikethrough~` - Strikethrough
  - `` `code` `` - Inline code
  - ``` ```code block``` ``` - Code block
  - `<url|text>` - Hyperlink
  """

  alias AshDispatch.Channel
  alias AshDispatch.Workers.SendWebhook

  require Logger

  @doc """
  Delivers Slack notification by enqueueing SendWebhook worker.

  ## Receipt Content

  Expected content structure:
  - `notification_message` - Message text (required, supports mrkdwn)
  - `slack_blocks` - Block Kit blocks (optional)
  - `slack_attachments` - Legacy attachments (optional)
  - `slack_username` - Bot username override (optional)
  - `slack_icon_emoji` - Bot icon emoji (optional, e.g., ":robot_face:")
  - `slack_icon_url` - Bot icon URL (optional)

  ## Channel Metadata

  Expected metadata:
  - `webhook_url` - Slack webhook URL (required)
  """
  def deliver(receipt, context, channel, _event_config) do
    webhook_url = get_webhook_url(channel)

    if webhook_url do
      # Build Slack payload
      payload = build_slack_payload(receipt.content, context)

      # Enqueue webhook worker
      job_args = %{
        receipt_id: receipt.id,
        webhook_url: webhook_url,
        payload: payload,
        headers: %{"Content-Type" => "application/json"}
      }

      case SendWebhook.new(job_args) |> Oban.insert() do
        {:ok, _job} ->
          # Mark receipt as scheduled
          updated_receipt =
            receipt
            |> Ash.Changeset.for_update(:schedule, %{})
            |> Ash.update!()

          Logger.info("Slack webhook job enqueued for receipt #{receipt.id}")
          {:ok, updated_receipt}

        {:error, reason} ->
          # Failed to enqueue - mark receipt as failed
          Logger.error("Failed to enqueue Slack webhook job: #{inspect(reason)}")

          updated_receipt =
            receipt
            |> Ash.Changeset.for_update(:mark_failed, %{
              error_message: "Failed to enqueue: #{inspect(reason)}"
            })
            |> Ash.update!()

          {:ok, updated_receipt}
      end
    else
      # No webhook URL configured - skip
      Logger.warning("Slack transport missing webhook_url for receipt #{receipt.id}, skipping")

      updated_receipt =
        receipt
        |> Ash.Changeset.for_update(:skip, %{
          error_message: "No webhook_url configured"
        })
        |> Ash.update!()

      {:ok, updated_receipt}
    end
  end

  # Private helpers

  defp get_webhook_url(%Channel{webhook_url: url}) when is_binary(url), do: url

  defp get_webhook_url(%Channel{opts: opts}) when is_map(opts) do
    opts["webhook_url"] || opts[:webhook_url]
  end

  defp get_webhook_url(_), do: nil

  defp build_slack_payload(content, _context) when is_map(content) do
    # Base payload with text
    payload = %{
      "text" => content["notification_message"] || content[:notification_message]
    }

    # Add blocks if provided (Block Kit - preferred format)
    payload =
      case content["slack_blocks"] || content[:slack_blocks] do
        nil -> payload
        blocks -> Map.put(payload, "blocks", blocks)
      end

    # Add attachments if provided (legacy format)
    payload =
      case content["slack_attachments"] || content[:slack_attachments] do
        nil -> payload
        attachments -> Map.put(payload, "attachments", attachments)
      end

    # Add username override if provided
    payload =
      case content["slack_username"] || content[:slack_username] do
        nil -> payload
        username -> Map.put(payload, "username", username)
      end

    # Add icon emoji if provided
    payload =
      case content["slack_icon_emoji"] || content[:slack_icon_emoji] do
        nil -> payload
        icon_emoji -> Map.put(payload, "icon_emoji", icon_emoji)
      end

    # Add icon URL if provided
    payload =
      case content["slack_icon_url"] || content[:slack_icon_url] do
        nil -> payload
        icon_url -> Map.put(payload, "icon_url", icon_url)
      end

    payload
  end

  defp build_slack_payload(_content, _context) do
    # Fallback for non-map content
    %{"text" => "Notification"}
  end
end
