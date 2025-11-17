defmodule AshDispatch.Workers.SendEmail do
  @moduledoc """
  Oban worker for sending emails asynchronously.

  This worker:
  1. Fetches the DeliveryReceipt by ID
  2. Marks receipt as `:sending`
  3. Sends the email via configured email backend
  4. Marks receipt as `:sent` or `:failed`

  ## Usage

  Jobs are enqueued automatically by `AshDispatch.Transports.Email`:

      # Email transport enqueues job
      Email.deliver(receipt, context, channel, event_config)

      # Worker processes job asynchronously
      %{
        "receipt_id" => "...",
        "recipient_email" => "user@example.com",
        "subject" => "Order Created",
        "from" => "orders@example.com",
        "html_body" => "<h1>Order #1234</h1>",
        "text_body" => "Order #1234 created"
      }

  ## Retries

  Oban handles retries automatically:
  - Max 5 attempts (configurable)
  - Exponential backoff (configurable)
  - Failed jobs can be manually retried

  ## Email Backend

  Currently mocked. Consuming apps should configure their email backend:

      # config/config.exs
      config :ash_dispatch,
        email_backend: MyApp.Emails.Backend

  The backend should implement `send_email/1`:

      defmodule MyApp.Emails.Backend do
        def send_email(%{
          to: to,
          from: from,
          subject: subject,
          html_body: html,
          text_body: text
        }) do
          # Send via Swoosh, Bamboo, etc.
          {:ok, %{id: "provider_message_id"}}
        end
      end
  """

  use Oban.Worker,
    queue: :emails,
    max_attempts: 5

  alias AshDispatch.Resources.DeliveryReceipt

  require Logger

  @doc """
  Processes email sending job.

  ## Job Args

  - `receipt_id` - DeliveryReceipt UUID
  - `recipient_email` - Email address to send to
  - `subject` - Email subject
  - `from` - Sender email address
  - `html_body` - HTML email body
  - `text_body` - Plain text email body

  ## Returns

  - `:ok` on success
  - `{:error, reason}` on failure (Oban will retry)
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    receipt_id = args["receipt_id"]

    Logger.info("Processing email job for receipt #{receipt_id}")

    # Fetch receipt
    case DeliveryReceipt |> Ash.get(receipt_id) do
      {:ok, receipt} ->
        process_email(receipt, args)

      {:error, error} ->
        Logger.error("Failed to fetch receipt #{receipt_id}: #{inspect(error)}")
        {:error, :receipt_not_found}
    end
  end

  # Private functions

  defp process_email(receipt, args) do
    # Mark as sending
    {:ok, receipt} = mark_sending(receipt)

    # Send email
    case send_email(args) do
      {:ok, provider_response} ->
        # Mark as sent
        mark_sent(receipt, provider_response)
        Logger.info("Email sent successfully for receipt #{receipt.id}")
        :ok

      {:error, reason} ->
        # Mark as failed (will be retried by Oban)
        mark_failed(receipt, reason)
        Logger.error("Email failed for receipt #{receipt.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp mark_sending(receipt) do
    receipt
    |> Ash.Changeset.for_update(:mark_sending, %{})
    |> Ash.update()
  end

  defp mark_sent(receipt, provider_response) do
    receipt
    |> Ash.Changeset.for_update(:mark_sent, %{
      provider_id: provider_response[:id],
      provider_response: provider_response
    })
    |> Ash.update!()
  end

  defp mark_failed(receipt, reason) do
    receipt
    |> Ash.Changeset.for_update(:mark_failed, %{
      error_message: inspect(reason)
    })
    |> Ash.update!()
  end

  defp send_email(args) do
    email_params = %{
      to: args["recipient_email"],
      from: args["from"],
      subject: args["subject"],
      html_body: args["html_body"],
      text_body: args["text_body"]
    }

    # Check for configured email backend
    case Application.get_env(:ash_dispatch, :email_backend) do
      nil ->
        # No backend configured - mock success for now
        Logger.info("""
        [MOCK] Would send email:
        To: #{email_params.to}
        From: #{email_params.from}
        Subject: #{email_params.subject}
        """)

        {:ok, %{id: "mock_#{System.unique_integer()}", mock: true}}

      backend ->
        # Call configured backend
        backend.send_email(email_params)
    end
  end
end
