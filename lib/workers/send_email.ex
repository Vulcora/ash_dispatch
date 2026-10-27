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
    # Only one job per receipt_id can be in available/scheduled/executing/retryable state.
    #
    # `:retryable` matters: a failed send leaves its job retryable (Oban's own
    # backoff) and its receipt `:failed` — which is exactly what the
    # RetryFailedDeliveries cron picks up. Without the state here the cron
    # enqueued a second job beside the one already waiting, and the two raced.
    unique: [keys: [:receipt_id], states: [:available, :scheduled, :executing, :retryable]]

  alias AshDispatch.Config
  alias AshDispatch.ContentMap
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
  - `attachments` - Optional list of attachments, each `%{"filename" => ...,
    "content_type" => ..., "data" => base64}` plus an optional `"type" =>
    "inline"` / `"cid" => ...` pair for inline images

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

  @doc false
  # Build a retry/send-now job for a receipt, carrying forward the original
  # job's attachments. Attachments are resolved once, at first enqueue, and
  # exist only in that job's args — without this, every retried email
  # silently loses its attachments (broken inline images included).
  def new_for_receipt(receipt) do
    %{receipt_id: receipt.id}
    |> maybe_put_original_attachments(receipt)
    |> new()
  end

  defp maybe_put_original_attachments(args, %{oban_job_id: job_id}) when is_integer(job_id) do
    case Config.repo().get(Oban.Job, job_id) do
      %Oban.Job{args: %{"attachments" => attachments}}
      when is_list(attachments) and attachments != [] ->
        Map.put(args, :attachments, attachments)

      _ ->
        args
    end
  rescue
    error ->
      Logger.warning(
        "SendEmail: could not carry attachments from original job #{inspect(job_id)}: #{inspect(error)}"
      )

      args
  end

  defp maybe_put_original_attachments(args, _receipt), do: args

  @doc false
  # The reply address for this send: the job's args first, then the receipt.
  #
  # The receipt is not merely a convenience. `new_for_receipt/1` builds a retry
  # from the receipt and carries NO content args at all — only `receipt_id` and
  # the attachments — so a `reply_to` that lived only in the first job's args
  # would be lost on every retry and every "send now". It is the same trap
  # attachments have their own handling for; here it is solved by the value
  # already being in `receipt.content`.
  #
  # `ContentMap.get_content/2` rather than `get_in/2`: the content has been
  # through JSONB and the key may be a string.
  def reply_to_for(args, receipt) do
    case args["reply_to"] do
      value when is_binary(value) and value != "" -> value
      _ -> ContentMap.get_content(Map.get(receipt, :content), :reply_to)
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
           :continue <- check_email_backend_configured(),
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

  @doc false
  # The params the email backend is called with. Public-but-undocumented
  # because `AshDispatch.Preview` calls it with the args the transport would
  # have enqueued: a preview's envelope is then the backend's envelope, by
  # construction.
  def email_params(receipt, args) do
    # Extract 'from' - handle both map format and string format
    # Fallback to receipt.content.from or default
    from = parse_from_field(args["from"] || ContentMap.get_content(receipt.content, :from))

    # Build email params, falling back to receipt fields if args are missing
    %{
      to: args["recipient_email"] || receipt.recipient,
      from: from,
      subject: args["subject"] || receipt.subject,
      reply_to: reply_to_for(args, receipt),
      html_body: args["html_body"] || receipt.body_html,
      text_body: args["text_body"] || receipt.body_text,
      attachments: decode_attachments(args["attachments"])
    }
    |> put_headers(headers_for(args, receipt))
  end

  @doc false
  # Extra headers for this send: the job's args first, then the receipt — the
  # same reasoning as `reply_to_for/2`, since a retry carries no content args.
  def headers_for(args, receipt) do
    case args["headers"] do
      headers when is_map(headers) and map_size(headers) > 0 ->
        headers

      _ ->
        case ContentMap.get_content(Map.get(receipt, :content), :headers) do
          headers when is_map(headers) -> headers
          _ -> %{}
        end
    end
    |> Map.new(fn {name, value} -> {to_string(name), value} end)
  end

  # Only when there are any, so a backend written before 0.8.6 is called with
  # exactly the params it always was.
  defp put_headers(params, headers) when map_size(headers) == 0, do: params
  defp put_headers(params, headers), do: Map.put(params, :headers, headers)

  defp send_email(receipt, args) do
    email_params = email_params(receipt, args)

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

  @doc false
  # Decode attachments from Oban job args (base64 `data` → raw binary) into the
  # shape the email backend expects:
  # `%{filename:, content_type:, data:, type:, cid:}`.
  # Robust against nil/missing (events without an `attachments/2` callback) and
  # against args enqueued before inline support — jobs already in flight carry
  # no `"type"`/`"cid"` and decode to `type: :attachment, cid: nil`, exactly
  # the previous behaviour.
  # Public-but-undocumented so the encode → decode round-trip is testable.
  def decode_attachments(nil), do: []

  def decode_attachments(list) when is_list(list) do
    Enum.flat_map(list, fn
      %{"filename" => filename, "content_type" => content_type, "data" => data_b64} = attachment ->
        case Base.decode64(data_b64) do
          {:ok, data} ->
            [
              %{
                filename: filename,
                content_type: content_type,
                data: data,
                type: decode_attachment_type(attachment["type"]),
                cid: attachment["cid"]
              }
            ]

          :error ->
            []
        end

      _ ->
        []
    end)
  end

  def decode_attachments(_), do: []

  # Never `String.to_atom/1` on job args (arbitrary input → atom-table growth):
  # only the known `"inline"` marker maps to an atom, everything else is a
  # regular attachment.
  defp decode_attachment_type("inline"), do: :inline
  defp decode_attachment_type(_), do: :attachment

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

  # A missing backend is a config state, not a delivery — skip, don't mock-send.
  defp check_email_backend_configured do
    if Config.email_backend() do
      :continue
    else
      Logger.warning("No :email_backend configured in :ash_dispatch config — email skipped")
      {:skip, "no email_backend configured"}
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

      # A manual trigger asked for the opt-out to be bypassed, and the receipt
      # records that it did (`Dispatcher.dispatch/4`, `:skip_preferences`).
      skip_preferences?(receipt) ->
        :send

      # No user_id on receipt - always send
      is_nil(receipt.user_id) ->
        :send

      # Check preferences
      true ->
        category = event_category(receipt)

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

  defp skip_preferences?(receipt) do
    case ContentMap.get_content(Map.get(receipt, :content), :manual_override) do
      override when is_map(override) ->
        ContentMap.get_content(override, :skip_preferences) == true

      _ ->
        false
    end
  end

  # Prefer the category the event module actually declares (`category` in
  # the dispatch DSL / `category/1` callback). Deriving it from the event id
  # by string munging only matches a preference field by coincidence —
  # "reseller_request.new_reseller_request" never mapped to any consumer's
  # preference schema, silently disabling those opt-out toggles.
  defp event_category(receipt) do
    with {:ok, module} <- AshDispatch.EventRegistry.find_module(receipt.event_id),
         category when not is_nil(category) <- declared_category(module) do
      category
    else
      _ -> event_id_to_category(receipt.event_id)
    end
  end

  defp declared_category(module) do
    module.category(nil)
  rescue
    _ -> nil
  end

  # Fallback: convert event_id to category atom (e.g., "orders.created" -> :orders_created)
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
