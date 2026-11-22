defmodule AshDispatch.Transports.Discord do
  use AshDispatch.Transport, atom: :discord, skip_receipt?: false

  @moduledoc """
  Discord webhook transport.

  Sends messages to Discord channels via webhooks (async via Oban).

  ## The body is sent as written

  A Discord message body is **not escaped** by this library, and neither is a
  Slack one. That is deliberate: both are markdown-ish formats where escaping
  would turn a deliberate `*bold*` into literal asterisks, and the body is
  normally an event's own sentence. It does mean the body is whatever went
  into it — a record's field, a customer's own name — so an event rendering
  untrusted text into a Discord or Slack body should expect that text to be
  read as formatting.

  Mentions are the one case where that is not merely cosmetic, so they are
  **off by default**: every payload carries
  `allowed_mentions: %{"parse" => []}` unless the event sets
  `discord_allowed_mentions` itself. Discord's own default is to parse every
  mention in the text, which means an `@everyone` in a company name pings a
  whole server. An event that genuinely wants to ping says so:

      content: [discord_allowed_mentions: %{"parse" => ["users"]}]

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

      # Or from the environment, read when the message is sent
      event :order_created,
        channels: [
          [
            transport: :discord,
            audience: :team,
            metadata: [webhook_url_env: "DISCORD_ORDERS_WEBHOOK_URL"]
          ]
        ]

  A Discord webhook URL is a credential. With `webhook_url_env` the job args
  carry only the variable's name and the worker reads the value when it sends,
  so the URL is never stored in `oban_jobs.args`; no log line carries it either
  way. An unset variable skips the receipt with a reason that names it. See
  `AshDispatch.Transports.WebhookUrl`.

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
  alias AshDispatch.Transports.Preferences
  alias AshDispatch.Transports.WebhookUrl
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
  def deliver(receipt, context, channel, event_config) do
    Preferences.with_consent(receipt, context, channel, event_config, fn ->
      do_deliver(receipt, context, channel)
    end)
  end

  defp do_deliver(receipt, context, channel) do
    case job_args(receipt, context, channel) do
      {:ok, job_args} ->
        case job_args
             |> SendWebhook.new(AshDispatch.Transport.Queue.opts(channel))
             |> Oban.insert() do
          {:ok, job} ->
            # Mark receipt as scheduled, in its own tenant, and record which
            # job it is: without the id the stranded sweep has no job to look
            # up and decides on age alone.
            updated_receipt =
              receipt
              |> AshDispatch.ReceiptStatus.mark_scheduled()
              |> AshDispatch.ReceiptStatus.put_oban_job_id(job.id)

            Logger.info("Discord webhook job enqueued for receipt #{receipt.id}")
            {:ok, updated_receipt}

          {:error, reason} ->
            # Failed to enqueue - mark receipt as failed
            Logger.error("Failed to enqueue Discord webhook job: #{inspect(reason)}")

            updated_receipt =
              AshDispatch.ReceiptStatus.mark_failed(
                receipt,
                "Failed to enqueue: #{inspect(reason)}"
              )

            {:ok, updated_receipt}
        end

      {:skip, reason} ->
        # Nothing to post to - skip
        Logger.warning("Discord transport: #{reason} for receipt #{receipt.id}, skipping")

        {:ok, AshDispatch.ReceiptStatus.mark_skipped(receipt, reason)}
    end
  end

  @doc """
  The `AshDispatch.Workers.SendWebhook` job args for a receipt, or why there
  are none.

  With `metadata.webhook_url_env` the args carry the variable's NAME under
  `"webhook_url_env"` and no URL; the worker reads the value when it sends.
  See `AshDispatch.Transports.WebhookUrl`. Public so the shape that lands in
  `oban_jobs.args` can be tested without an Oban instance.
  """
  @spec job_args(map(), map(), Channel.t()) :: {:ok, map()} | {:skip, String.t()}
  def job_args(receipt, context, channel) do
    with {:ok, target} <- WebhookUrl.target(channel) do
      args =
        target
        |> Map.merge(%{
          "receipt_id" => receipt.id,
          "payload" => build_discord_payload(receipt.content, context),
          "headers" => %{"Content-Type" => "application/json"}
        })
        |> put_tenant(AshDispatch.Tenancy.of(receipt))

      {:ok, args}
    end
  end

  # Private helpers

  # The worker reads the receipt by id, so the job says which schema it is in.
  defp put_tenant(args, nil), do: args

  defp put_tenant(args, tenant),
    do: Map.put(args, "tenant", AshDispatch.Tenancy.receipt_prefix(tenant))

  @doc false
  # Public-but-undocumented so the mention default can be tested directly:
  # it is the one thing in this payload that is a safety decision rather than
  # a shape.
  def build_payload(content, context), do: build_discord_payload(content, context)

  defp build_discord_payload(content, _context) when is_map(content) do
    # Base payload with content.
    #
    # `allowed_mentions: %{parse: []}` unless the event says otherwise: a
    # message body carries whatever a record held, and `@everyone` in a
    # customer's company name pings a whole server. Discord's default is to
    # parse every mention in the text, so the safe answer has to be stated.
    # An event that wants to ping says so with
    # `content: [discord_allowed_mentions: %{"parse" => ["users"]}]`.
    payload = %{
      "content" => get_content(content, :notification_message),
      "allowed_mentions" => get_content(content, :discord_allowed_mentions) || %{"parse" => []}
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
    %{"content" => "Notification", "allowed_mentions" => %{"parse" => []}}
  end
end
