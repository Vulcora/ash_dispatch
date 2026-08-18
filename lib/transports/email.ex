defmodule AshDispatch.Transports.Email do
  use AshDispatch.Transport, atom: :email, skip_receipt?: false

  @moduledoc """
  Email transport via Oban jobs.

  Enqueues email delivery jobs for asynchronous sending.

  ## Behavior

  1. Checks the preferences of the receipt's own recipient
     (`AshDispatch.UserPreference.allows_receipt?/4`)
  2. Enqueues an Oban job for this receipt
  3. Updates receipt status to `:scheduled`

  ## Status Flow

  ```
  pending → scheduled (job enqueued)
          ↘ skipped (user opted out or no recipients)

  Later (in Oban worker):
  scheduled → sending (job started)
           → sent (email delivered)
           ↘ failed (delivery error)
  ```

  ## Delayed Delivery

  Supports delayed delivery via channel's `time` field:

      channel = %Channel{
        transport: :email,
        time: {:in, 300}  # Deliver in 5 minutes
      }

      channel = %Channel{
        transport: :email,
        time: {:at, ~U[2026-09-01 07:00:00Z]}  # Deliver at an absolute time
      }

  A `{:at, …}` in the past delivers now. `{:window, map}` is deprecated
  and delivers immediately.

  ## Example

      receipt = %{
        content: %{
          subject: "Order Created",
          from: "orders@example.com",
          html_body: "<h1>Order #1234</h1>",
          text_body: "Order #1234 created"
        }
      }

      Email.deliver(receipt, context, channel, event_config)
      # -> Enqueues Oban job
      # -> Returns {:ok, updated_receipt}
  """

  alias AshDispatch.Channel
  alias AshDispatch.Config
  alias AshDispatch.EventResolver

  require Logger

  @doc """
  Delivers email by enqueueing Oban job.

  ## Parameters

  - `receipt` - DeliveryReceipt map
  - `context` - Event context
  - `channel` - Channel configuration
  - `event_config` - Event configuration

  ## Returns

  - `{:ok, updated_receipt}` on success
  - `{:error, reason}` on failure
  """
  def deliver(receipt, context, channel, event_config) do
    # Check the preferences of THIS receipt's recipient. A receipt is one
    # recipient, so a fan-out evaluates one verdict per recipient — reading
    # `context.user` here applied the event subject's verdict to all N.
    if not AshDispatch.UserPreference.allows_receipt?(receipt, context, channel, event_config) do
      Logger.info(
        "User #{inspect(Map.get(receipt, :user_id))} opted out of #{context.event_id} via #{channel.transport}, skipping"
      )

      updated_receipt =
        receipt
        |> Ash.Changeset.for_update(:skip, %{error_message: "user_opted_out"})
        |> Ash.update!(authorize?: false)

      {:ok, updated_receipt}
    else
      # Receipt now corresponds to a single recipient (user_id and recipient in receipt)
      # Enqueue one Oban job for this receipt
      result = enqueue_email_job_for_receipt(receipt, context, channel)

      # Update receipt status with oban_job_id
      updated_receipt = update_receipt_with_job(receipt, result, channel)

      {:ok, updated_receipt}
    end
  rescue
    error ->
      Logger.error("""
      Email transport failed to enqueue job
      Event: #{context.event_id}
      Error: #{inspect(error)}
      """)

      {:error, error}
  end

  # Private functions

  # Enqueue Oban job for the receipt (one receipt = one recipient now)
  defp enqueue_email_job_for_receipt(receipt, context, channel) do
    # Build job args from receipt (which now has all recipient info)
    from = get_from_field(receipt)

    args = %{
      "receipt_id" => receipt.id,
      # Receipt already has recipient email
      "recipient_email" => receipt.recipient,
      "event_id" => context.event_id,
      "subject" => receipt.subject,
      "from" => from,
      "html_body" => receipt.body_html,
      "text_body" => receipt.body_text,
      "attachments" => resolve_attachments(context, channel)
    }

    # Calculate schedule time
    schedule_in = schedule_seconds(channel)

    # Enqueue Oban job
    job_changeset =
      AshDispatch.Workers.SendEmail.new(args, schedule_in: schedule_in)

    case Oban.insert(job_changeset) do
      {:ok, job} ->
        Logger.debug("Enqueued email job #{job.id} for receipt #{receipt.id}")
        {:ok, job}

      {:error, error} ->
        Logger.error("Failed to enqueue email job: #{inspect(error)}")
        {:error, error}
    end
  end

  @doc false
  # Resolve the event's attachments (optional `attachments/2` callback) and
  # base64-encode the raw binary `data` so it survives JSONB Oban-arg
  # serialization. Events without the callback → `[]` (EventResolver default).
  # `SendEmail` decodes these back to binary before handing them to the backend.
  # Public-but-undocumented so the encode → decode round-trip is testable
  # without an Oban instance.
  def resolve_attachments(context, channel) do
    event_attachments =
      case EventResolver.find_module(context.event_id) do
        {:ok, module} -> EventResolver.attachments(module, context, channel)
        _ -> []
      end

    Enum.map(default_attachments() ++ event_attachments, &encode_attachment/1)
  end

  # App-wide attachments included in EVERY outgoing email, configured as
  #
  #     config :ash_dispatch,
  #       default_email_attachments: {MyApp.EmailAssets, :defaults, []}
  #
  # The MFA (or zero-arity fun) returns a list of attachment maps in the same
  # shape as `attachments/2`. Typical use: an inline (`type: :inline`) logo
  # referenced from a shared layout as `<img src="cid:logo.png">`, so every
  # mail renders it without per-event `attachments/2` implementations and
  # without the recipient approving remote images. Resolution failures are
  # logged and degrade to [] — a branding asset must never block delivery.
  defp default_attachments do
    case Application.get_env(:ash_dispatch, :default_email_attachments) do
      nil -> []
      {mod, fun, args} -> List.wrap(apply(mod, fun, args))
      fun when is_function(fun, 0) -> List.wrap(fun.())
    end
  rescue
    error ->
      Logger.warning(
        "default_email_attachments resolution failed, sending without: #{inspect(error)}"
      )

      []
  end

  # `"type"` is only written for `:inline` attachments and `"cid"` only when
  # the event supplied one, so a plain attachment serializes byte-for-byte as
  # before inline support (nothing new in the JSONB args, nothing for older
  # workers to choke on).
  defp encode_attachment(attachment) do
    %{
      "filename" => attachment.filename,
      "content_type" => attachment.content_type,
      "data" => Base.encode64(attachment.data)
    }
    |> put_unless_nil("type", encode_attachment_type(Map.get(attachment, :type)))
    |> put_unless_nil("cid", Map.get(attachment, :cid))
  end

  defp encode_attachment_type(:inline), do: "inline"
  # `:attachment` (and a missing `:type`) is the default — left out of the args.
  defp encode_attachment_type(_), do: nil

  defp put_unless_nil(args, _key, nil), do: args
  defp put_unless_nil(args, key, value), do: Map.put(args, key, value)

  # Update receipt with oban_job_id and mark as scheduled
  # NOTE: In Oban inline testing mode, the job executes immediately within insert(),
  # so the receipt may already be in a terminal state (sent/failed) when we return.
  defp update_receipt_with_job(receipt, result, _channel) do
    case result do
      {:ok, job} ->
        # Refetch to get current state (may have changed in inline mode)
        case Ash.get(receipt.__struct__, receipt.id, authorize?: false) do
          {:ok, current_receipt} ->
            if current_receipt.status in [:pending] do
              # Only schedule if still pending
              current_receipt
              |> Ash.Changeset.for_update(:schedule, %{oban_job_id: job.id})
              |> Ash.update!(authorize?: false)
            else
              # Already processed (inline mode) - just return current state
              Logger.debug(
                "Receipt #{receipt.id} already in #{current_receipt.status} state, skipping schedule"
              )

              current_receipt
            end

          {:error, _} ->
            # Receipt not found, return original
            receipt
        end

      {:error, reason} ->
        receipt
        |> Ash.Changeset.for_update(:mark_failed, %{error_message: inspect(reason)})
        |> Ash.update!(authorize?: false)
    end
  end

  defp get_from_field(receipt) do
    cond do
      # From field stored as map with name/email (from event module)
      is_map(receipt.content[:from]) ->
        receipt.content[:from]

      # From field is a tuple {name, email} - convert to map for JSON serialization
      is_tuple(receipt.content[:from]) ->
        {name, email} = receipt.content[:from]
        %{"name" => name, "email" => email}

      # From field is a string email address
      is_binary(receipt.content[:from]) ->
        receipt.content[:from]

      # Fallback to configured default
      true ->
        %{"name" => Config.default_from_name(), "email" => Config.default_from_email()}
    end
  end

  @doc false
  # The channel's delivery time as an Oban `schedule_in` value.
  #
  # `{:at, %DateTime{}}` used to fall into the catch-all and send
  # IMMEDIATELY — the documented absolute-time API silently did nothing.
  # It now goes through `Channel.calculate_delay/1`, clamped at 0 so a
  # past datetime means "now" rather than a negative schedule_in.
  #
  # Public-but-undocumented so the mapping is testable without an Oban
  # instance (same reason as `resolve_attachments/2`).
  def schedule_seconds(%Channel{time: {:in, seconds}}), do: seconds

  def schedule_seconds(%Channel{time: {:at, %DateTime{}}} = channel) do
    channel
    |> Channel.calculate_delay()
    |> max(0)
  end

  def schedule_seconds(%Channel{time: {:window, _window}}) do
    Channel.warn_window_deprecated()
    0
  end

  def schedule_seconds(_), do: 0
end
