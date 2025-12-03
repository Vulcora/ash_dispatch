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

  ## Idempotency

  This worker is designed to be idempotent and handles duplicate jobs gracefully:

  - **Unique jobs**: Only one job per `receipt_id` can be in available/scheduled/executing
    state at a time. This prevents duplicate jobs from "send now" while original is queued.
  - **Terminal state check**: If receipt is already in `:sent`, `:skipped`, or `:failed_permanent`
    state, the job completes successfully without retrying.
  - **Race condition handling**: If state transition fails due to concurrent processing,
    the job completes successfully (another job already handled it).

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
    max_attempts: 5,
    # Prevent duplicate jobs for the same receipt (e.g., from "send now" while original is queued)
    # Only one job per receipt_id can be in available/scheduled/executing state
    unique: [keys: [:receipt_id], states: [:available, :scheduled, :executing]]

  alias AshDispatch.Config
  alias AshDispatch.ReceiptStatus

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

    # Fetch receipt (bypass authorization - workers run as system)
    case Config.delivery_receipt_resource() |> Ash.get(receipt_id, authorize?: false) do
      {:ok, receipt} ->
        process_email(receipt, args)

      {:error, error} ->
        Logger.error("Failed to fetch receipt #{receipt_id}: #{inspect(error)}")
        {:error, :receipt_not_found}
    end
  end

  # Private functions

  defp process_email(receipt, args) do
    # Early exit for terminal states - handles duplicate job scenarios gracefully
    # This can happen when "send now" creates a new job while original is processing
    if receipt.status in [:sent, :skipped, :failed_permanent] do
      Logger.info(
        "Receipt #{receipt.id} already in terminal state #{receipt.status}, job completing as success"
      )

      :ok
    else
      # Check skip_email_delivery config first (dev mode)
      # Then check skip_if_read policy and user preferences
      with :continue <- check_skip_email_delivery(),
           :continue <- check_skip_if_read_policy(receipt),
           :send <- check_user_preferences(receipt) do
        # Mark as sending - handle race condition gracefully
        case ReceiptStatus.mark_sending(receipt) do
          {:ok, receipt} ->
            # Send email (pass receipt for field fallback)
            case send_email(receipt, args) do
              {:ok, provider_response} ->
                # Mark as sent
                ReceiptStatus.mark_sent(receipt, provider_response)
                Logger.info("Email sent successfully for receipt #{receipt.id}")
                :ok

              {:error, reason} ->
                # Mark as failed (will be retried by Oban)
                ReceiptStatus.mark_failed(receipt, reason)
                Logger.error("Email failed for receipt #{receipt.id}: #{inspect(reason)}")
                {:error, reason}
            end

          {:error, %Ash.Error.Invalid{errors: errors}} ->
            # Check if it's a state machine transition error (duplicate job scenario)
            if Enum.any?(errors, &match?(%AshStateMachine.Errors.NoMatchingTransition{}, &1)) do
              Logger.info(
                "Receipt #{receipt.id} state transition conflict (likely duplicate job), completing as success"
              )

              :ok
            else
              # Some other validation error - let Oban retry
              Logger.error("Receipt #{receipt.id} update failed: #{inspect(errors)}")
              {:error, errors}
            end

          {:error, reason} ->
            Logger.error("Receipt #{receipt.id} mark_sending failed: #{inspect(reason)}")
            {:error, reason}
        end
      else
        {:skip, reason} ->
          # Either policy check failed - mark as skipped
          ReceiptStatus.mark_skipped(receipt, reason)
          Logger.info("Email skipped for receipt #{receipt.id}: #{reason}")
          :ok
      end
    end
  end

  defp send_email(receipt, args) do
    # Extract 'from' - handle both map format and string format
    # Fallback to receipt.content.from or default
    from = parse_from_field(args["from"] || get_in(receipt.content, [:from]))

    # Build email params, falling back to receipt fields if args are missing
    email_params = %{
      to: args["recipient_email"] || receipt.recipient,
      from: from,
      subject: args["subject"] || receipt.subject,
      html_body: args["html_body"] || receipt.body_html,
      text_body: args["text_body"] || receipt.body_text
    }

    # Check for configured email backend
    case Config.email_backend() do
      nil ->
        # No backend configured - mock success for now
        Logger.info("""
        [MOCK] Would send email:
        To: #{email_params.to}
        From: #{inspect(email_params.from)}
        Subject: #{email_params.subject}
        """)

        {:ok, %{id: "mock_#{System.unique_integer()}", mock: true}}

      backend ->
        # Call configured backend
        backend.send_email(email_params)
    end
  end

  defp parse_from_field(%{"name" => name, "email" => email}), do: {name, email}
  defp parse_from_field(%{"email" => email}), do: email
  defp parse_from_field(from) when is_binary(from), do: from
  defp parse_from_field({_, _} = from), do: from
  # Handle JSON-serialized tuple (stored as array)
  defp parse_from_field([name, email]) when is_binary(name) and is_binary(email),
    do: {name, email}

  # Fallback to configured default
  defp parse_from_field(_), do: Config.default_from_email()

  # Check if email delivery is disabled (dev mode)
  defp check_skip_email_delivery do
    if Config.skip_email_delivery?() do
      {:skip, "email delivery disabled (dev mode)"}
    else
      :continue
    end
  end

  # Check skip_if_read policy
  defp check_skip_if_read_policy(receipt) do
    # Get policy from receipt content
    policy = get_in(receipt.content, ["policy"]) || get_in(receipt.content, [:policy])

    if policy == :skip_if_read || policy == "skip_if_read" do
      # Load notification and check if it's read
      case load_notification(receipt) do
        {:ok, notification} ->
          if notification.read do
            {:skip, "notification already read"}
          else
            :continue
          end

        {:error, _} ->
          # If we can't load notification, continue with sending
          :continue
      end
    else
      # No skip_if_read policy - continue
      :continue
    end
  end

  defp load_notification(receipt) do
    if receipt.notification_id do
      case Ash.get(Config.notification_resource(), receipt.notification_id, authorize?: false) do
        {:ok, notification} -> {:ok, notification}
        error -> error
      end
    else
      {:error, :no_notification_id}
    end
  end

  # Check user email preferences
  defp check_user_preferences(receipt) do
    # Get preference provider from config
    preference_provider = Config.preference_provider()

    cond do
      # No preference provider configured - always send
      is_nil(preference_provider) ->
        :send

      # No user_id on receipt - always send
      is_nil(receipt.user_id) ->
        :send

      # Check preferences
      true ->
        category = event_id_to_category(receipt.event_id)

        case preference_provider.get_preferences(receipt.user_id) do
          {:ok, preferences} ->
            if preference_provider.preference_enabled?(preferences, category) do
              :send
            else
              {:skip, "User opted out of this email category"}
            end

          {:error, _reason} ->
            # If we can't fetch preferences, default to sending
            # (better to send than to silently skip)
            :send
        end
    end
  end

  # Convert event_id to category atom (e.g., "orders.created" -> :orders_created)
  defp event_id_to_category(event_id) do
    event_id
    |> String.replace(".", "_")
    |> String.to_atom()
  rescue
    ArgumentError ->
      # If atom doesn't exist, return nil (will default to sending)
      nil
  end
end
