defmodule AshDispatch.Workers.SendWebhook do
  @moduledoc """
  Oban worker for sending webhooks asynchronously.

  This worker:
  1. Fetches the DeliveryReceipt by ID
  2. Marks receipt as `:sending`
  3. Sends HTTP POST to webhook URL
  4. Marks receipt as `:sent` or `:failed`

  ## Usage

  Jobs are enqueued automatically by webhook transports (Discord, Slack, generic Webhook):

      # Discord transport enqueues job
      Discord.deliver(receipt, context, channel, event_config)

      # Worker processes job asynchronously
      %{
        "receipt_id" => "...",
        "webhook_url" => "https://discord.com/api/webhooks/...",
        "payload" => %{
          "content" => "Order #1234 created",
          "embeds" => [...]
        },
        "headers" => %{
          "Content-Type" => "application/json"
        }
      }

  ## Retries

  Oban handles retries automatically:
  - Max 5 attempts (configurable)
  - Exponential backoff (configurable)
  - Failed jobs can be manually retried

  ## HTTP Client

  Uses Req for HTTP requests with:
  - Automatic retries for network errors
  - Timeout handling (10 seconds default)
  - JSON encoding/decoding
  - Comprehensive error reporting

  ## Webhook Formats

  Discord and Slack use different JSON formats:

  ### Discord
      {
        "content": "Message text",
        "embeds": [{
          "title": "Order Created",
          "description": "Order #1234",
          "color": 5814783
        }]
      }

  ### Slack
      {
        "text": "Message text",
        "blocks": [{
          "type": "section",
          "text": {"type": "mrkdwn", "text": "Order #1234"}
        }]
      }
  """

  use Oban.Worker,
    queue: :webhooks,
    max_attempts: 5

  alias AshDispatch.Config
  alias AshDispatch.ReceiptStatus

  require Logger

  @doc """
  Processes webhook sending job.

  ## Job Args

  - `receipt_id` - DeliveryReceipt UUID
  - `webhook_url` - Full webhook URL
  - `payload` - JSON payload to send
  - `headers` - Optional HTTP headers (defaults to JSON content type)

  ## Returns

  - `:ok` on success (2xx response)
  - `{:error, reason}` on failure (Oban will retry)
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    receipt_id = args["receipt_id"]

    Logger.info("Processing webhook job for receipt #{receipt_id}")

    # Fetch receipt (bypass authorization - workers run as system)
    case Config.delivery_receipt_resource() |> Ash.get(receipt_id, authorize?: false) do
      {:ok, receipt} ->
        process_webhook(receipt, args)

      {:error, error} ->
        Logger.error("Failed to fetch receipt #{receipt_id}: #{inspect(error)}")
        {:error, :receipt_not_found}
    end
  end

  # Private functions

  defp process_webhook(receipt, args) do
    # Mark as sending
    {:ok, receipt} = ReceiptStatus.mark_sending(receipt)

    # Send webhook
    case send_webhook(args) do
      {:ok, response} ->
        # Mark as sent
        ReceiptStatus.mark_sent(receipt, response)
        Logger.info("Webhook sent successfully for receipt #{receipt.id}")
        :ok

      {:error, reason} ->
        # Mark as failed (will be retried by Oban)
        ReceiptStatus.mark_failed(receipt, reason)
        Logger.error("Webhook failed for receipt #{receipt.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp send_webhook(args) do
    webhook_url = args["webhook_url"]
    payload = args["payload"]
    headers = args["headers"] || %{"Content-Type" => "application/json"}

    Logger.debug("""
    Sending webhook:
    URL: #{webhook_url}
    Payload: #{inspect(payload, pretty: true)}
    Headers: #{inspect(headers)}
    """)

    # Use Req to send HTTP POST
    case Req.post(webhook_url,
           json: payload,
           headers: headers,
           receive_timeout: 10_000,
           # We handle retries via Oban
           retry: false
         ) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        # Success - extract any useful info from response
        response_data = %{
          id: extract_id_from_response(response),
          status: status,
          body: response.body
        }

        Logger.info("Webhook delivered successfully: status=#{status}, url=#{webhook_url}")
        {:ok, response_data}

      {:ok, %Req.Response{status: status, body: body}} ->
        # HTTP error (4xx, 5xx)
        error = %{
          status: status,
          body: body,
          reason: "HTTP #{status} response"
        }

        Logger.warning(
          "Webhook HTTP error: status=#{status}, url=#{webhook_url}, body=#{inspect(body)}"
        )

        {:error, error}

      {:error, error} ->
        # Network error, timeout, etc.
        Logger.error("Webhook request failed: #{inspect(error)}, url=#{webhook_url}")
        {:error, error}
    end
  end

  # Extract ID from response (if available)
  # Discord and Slack typically return message IDs
  defp extract_id_from_response(%Req.Response{body: body}) when is_map(body) do
    # Try common ID fields
    body["id"] || body["message_id"] || body["ts"] || generate_id()
  end

  defp extract_id_from_response(_), do: generate_id()

  defp generate_id do
    "webhook_#{System.unique_integer([:positive])}"
  end
end
