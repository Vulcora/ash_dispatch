defmodule AshDispatch.Transports.Discord do
  @moduledoc """
  Discord webhook transport.

  Sends messages to Discord channels via webhooks (async via Oban).

  ## Configuration

  Requires `webhook_url` in channel metadata or via callback:

      # Inline configuration
      event :order_created,
        channels: [
          [
            transport: :discord,
            audience: :team,
            metadata: [
              webhook_url: "https://discord.com/api/webhooks/..."
            ]
          ]
        ]

      # Or via callback module
      def channels(context) do
        [
          %Channel{
            transport: :discord,
            audience: :team,
            metadata: %{
              webhook_url: get_discord_webhook_url(:orders)
            }
          }
        ]
      end

  ## Content

  Discord messages support:
  - `notification_message` - Simple text content
  - `discord_embed` - Rich embed with title, description, color, fields
  - `discord_username` - Override webhook username
  - `discord_avatar_url` - Override webhook avatar

  Example with embed:

      content: [
        notification_message: "New order received!",
        discord_embed: %{
          title: "Order {{id}} Created",
          description: "Customer: {{user.name}}",
          color: 5814783,  # Blue color (hex: 58B9FF)
          fields: [
            %{name: "Total", value: "${{total}}", inline: true},
            %{name: "Items", value: "{{item_count}}", inline: true}
          ]
        }
      ]

  ## Discord Embed Colors

  - Success (Green): 5763719 (0x57F287)
  - Info (Blue): 5814783 (0x58B9FF)
  - Warning (Yellow): 16776960 (0xFFFF00)
  - Error (Red): 15548997 (0xED4245)
  """

  import AshDispatch.ContentMap

  alias AshDispatch.Channel
  alias AshDispatch.Workers.SendWebhook

  require Logger

  @doc """
  Delivers Discord notification by enqueueing SendWebhook worker.

  ## Receipt Content

  Expected content structure:
  - `notification_message` - Message text (required)
  - `discord_embed` - Embed object (optional)
  - `discord_username` - Webhook username override (optional)
  - `discord_avatar_url` - Webhook avatar override (optional)

  ## Channel Metadata

  Expected metadata:
  - `webhook_url` - Discord webhook URL (required)
  """
  def deliver(receipt, context, channel, _event_config) do
    webhook_url = get_webhook_url(channel)

    if webhook_url do
      # Build Discord payload
      payload = build_discord_payload(receipt.content, context)

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

          Logger.info("Discord webhook job enqueued for receipt #{receipt.id}")
          {:ok, updated_receipt}

        {:error, reason} ->
          # Failed to enqueue - mark receipt as failed
          Logger.error("Failed to enqueue Discord webhook job: #{inspect(reason)}")

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
      Logger.warning("Discord transport missing webhook_url for receipt #{receipt.id}, skipping")

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

  defp build_discord_payload(content, _context) when is_map(content) do
    # Base payload with content
    payload = %{
      "content" => get_content(content, :notification_message)
    }

    # Add embed if provided
    payload =
      case get_content(content, :discord_embed) do
        nil -> payload
        embed -> Map.put(payload, "embeds", [embed])
      end

    # Add username override if provided
    payload =
      case get_content(content, :discord_username) do
        nil -> payload
        username -> Map.put(payload, "username", username)
      end

    # Add avatar override if provided
    payload =
      case get_content(content, :discord_avatar_url) do
        nil -> payload
        avatar_url -> Map.put(payload, "avatar_url", avatar_url)
      end

    payload
  end

  defp build_discord_payload(_content, _context) do
    # Fallback for non-map content
    %{"content" => "Notification"}
  end
end
