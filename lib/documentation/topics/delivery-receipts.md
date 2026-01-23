# Delivery Receipts

Delivery receipts track the lifecycle of every notification sent through AshDispatch. This guide covers the receipt model, status flow, and available actions for managing deliveries.

## What Delivery Receipts Track

Every time a notification is dispatched, a `DeliveryReceipt` is created to track:

- **Recipient information** - Who the notification is for (email, user_id, etc.)
- **Content** - Full email subject, body, and any additional content
- **Status** - Current delivery state (pending, sent, failed, etc.)
- **Provider data** - Response from email provider, message IDs
- **Timing** - When created, sent, delivered, opened, clicked
- **Source** - What triggered the notification (order, ticket, etc.)

This provides a complete audit trail and enables:
- Retry failed deliveries
- Debug delivery issues
- Track engagement (opens, clicks)
- User notification history

## Status Flow

Delivery receipts follow a state machine pattern:

```
                    ┌─────────────┐
                    │   pending   │
                    └──────┬──────┘
                           │
              ┌────────────┼────────────┐
              ▼            ▼            ▼
        ┌──────────┐ ┌──────────┐ ┌──────────┐
        │scheduled │ │ skipped  │ │  (sync)  │
        └────┬─────┘ └──────────┘ └────┬─────┘
             │                         │
             ▼                         │
        ┌──────────┐                   │
        │ sending  │◄──────────────────┘
        └────┬─────┘
             │
       ┌─────┴─────┐
       ▼           ▼
  ┌────────┐  ┌────────┐
  │  sent  │  │ failed │──────┐
  └────────┘  └────┬───┘      │
                   │          │ (max retries)
                   │ (retry)  ▼
                   │    ┌─────────────────┐
                   └───►│ failed_permanent │
                        └─────────────────┘
```

### Status Descriptions

| Status | Description |
|--------|-------------|
| `pending` | Just created, not yet processed |
| `scheduled` | Oban job enqueued for async delivery |
| `sending` | Currently being sent |
| `sent` | Successfully delivered to provider |
| `failed` | Delivery failed, may be retried |
| `failed_permanent` | Won't retry (invalid email, unsubscribed) |
| `skipped` | Intentionally not sent (user opted out) |

## Available Actions

### Core Status Transitions

These actions are typically called by workers and internal processes:

```elixir
# Mark as sending (worker starting delivery)
Ash.update(receipt, :mark_sending)

# Mark as sent (delivery successful)
Ash.update(receipt, :mark_sent, %{
  provider_id: "msg_abc123",
  provider_response: %{"status" => "sent"}
})

# Mark as failed (delivery failed, will retry)
Ash.update(receipt, :mark_failed, %{
  error_message: "Connection timeout"
})

# Mark as permanently failed (won't retry)
Ash.update(receipt, :mark_failed_permanent, %{
  error_message: "Invalid email address"
})

# Skip delivery (user opted out)
Ash.update(receipt, :skip, %{
  error_message: "User disabled notifications"
})
```

### Manual Actions (Admin UI)

#### send_now

The `send_now` action allows administrators to manually trigger delivery for a scheduled or pending receipt. This is useful for:

- **Retrying stuck deliveries** - When a job is stuck in scheduled state
- **Testing in production** - Trigger a specific email immediately
- **Support requests** - Resend a notification to a user

**Usage:**

```elixir
# From admin UI or IEx
receipt
|> Ash.Changeset.for_update(:send_now, %{}, actor: current_admin)
|> Ash.update(authorize?: true)
```

**Behavior:**
- Creates a new Oban job to process the delivery immediately
- Only works from `scheduled` or `pending` status
- Respects configured authorization (see below)

**Authorization:**

By default, any authenticated actor can use `send_now`. To restrict it (e.g., super admins only), configure an authorizer:

```elixir
# config/config.exs
config :ash_dispatch,
  send_now_authorizer: MyApp.Deliveries.SendNowAuthorizer
```

```elixir
# lib/my_app/deliveries/send_now_authorizer.ex
defmodule MyApp.Deliveries.SendNowAuthorizer do
  def authorize(%{super_admin: true}), do: :ok
  def authorize(_actor), do: {:error, "Only super admins can manually trigger email sending"}
end
```

See [Configuration](configuration.md#send-now-authorizer) for full documentation.

#### retry

The `retry` action re-queues a failed delivery for another attempt:

```elixir
receipt
|> Ash.Changeset.for_update(:retry, %{}, actor: current_admin)
|> Ash.update(authorize?: true)
```

**Behavior:**
- Only works from `failed` status
- Increments `retry_count`
- Creates new Oban job
- Validates against max retry limit

### Recording Webhook Events

When email providers send webhooks (delivery confirmations, opens, clicks), use `record_webhook_event`:

```elixir
Ash.update(receipt, :record_webhook_event, %{
  delivered_at: DateTime.utc_now(),
  provider_response: webhook_payload
})
```

Supported event timestamps:
- `sent_at` - Email accepted by provider
- `delivered_at` - Email delivered to inbox
- `delivery_delayed_at` - Delivery delayed
- `failed_at` - Delivery failed
- `opened_at` - Email opened
- `clicked_at` - Link clicked
- `bounced_at` - Email bounced
- `complained_at` - Spam complaint received

## Querying Receipts

### List all receipts (admin)

```elixir
DeliveryReceipt
|> Ash.Query.for_read(:list_all, %{
  status: :failed,
  transport: :email
})
|> Ash.read(actor: admin, authorize?: true)
```

### List for specific user

```elixir
DeliveryReceipt
|> Ash.Query.for_read(:list_for_user, %{user_id: user_id})
|> Ash.read(actor: admin, authorize?: true)
```

### Find by provider ID (webhooks)

```elixir
DeliveryReceipt
|> Ash.Query.for_read(:get_by_provider_id, %{provider_id: "msg_abc123"})
|> Ash.read_one(authorize?: false)
```

## Calculated Fields

Delivery receipts include useful calculated fields:

| Field | Description |
|-------|-------------|
| `oban_job` | The associated Oban job (if any) |
| `source_url` | URL path to the source resource |
| `source_label` | Human-readable label for source type |
| `admin_url` | Admin-specific URL for the source |
| `from_email` | Sender email address extracted from content |
| `from_name` | Sender name extracted from content |

These are useful for building admin UIs that link back to the originating record.

### Sender Information

The `from_email` and `from_name` calculations extract sender information from the stored `content` field:

```elixir
# Load sender info with the receipt
receipt = Ash.get!(DeliveryReceipt, id, load: [:from_email, :from_name])

# Display sender
"#{receipt.from_name} <#{receipt.from_email}>"
# => "Siteflow <noreply@siteflow.se>"
```

This is useful for:
- Displaying the sender in admin UIs
- Debugging which domain emails were sent from (staging vs production)
- Filtering receipts by sender domain

## Building an Admin UI

A typical delivery receipt admin interface might include:

### List View
- Filter by status, transport, event_id, audience
- Show recipient, status, sent_at
- Actions: View, Retry, Send Now

### Detail View
- Full receipt information
- Email content preview (subject, body)
- Provider response
- Timeline of status changes
- Link to source resource
- Oban job details

### Example LiveView

```elixir
def handle_event("send_now", %{"id" => id}, socket) do
  receipt = Deliveries.get_receipt!(id)

  case receipt
       |> Ash.Changeset.for_update(:send_now, %{}, actor: socket.assigns.current_user)
       |> Ash.update(authorize?: true) do
    {:ok, _} ->
      {:noreply, put_flash(socket, :info, "Email queued for immediate delivery")}

    {:error, error} ->
      {:noreply, put_flash(socket, :error, Exception.message(error))}
  end
end
```

## Automatic Retry

AshDispatch includes automatic retry for failed deliveries via Oban cron:

```elixir
# In your Oban config
config :my_app, Oban,
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       # Retry failed emails every 15 minutes
       {"*/15 * * * *", AshDispatch.Workers.RetryFailedEmails, max_attempts: 1}
     ]}
  ]
```

The retry worker:
- Finds receipts in `failed` status with `retry_count < max_retries`
- Re-queues them for delivery
- Marks permanently failed after max retries exceeded

## Best Practices

### 1. Use ReceiptStatus helper

For status updates in custom workers, use the centralized helper:

```elixir
alias AshDispatch.ReceiptStatus

# Instead of manual changeset creation
{:ok, receipt} = ReceiptStatus.mark_sending(receipt)
ReceiptStatus.mark_sent(receipt, provider_response)
```

### 2. Store provider IDs

Always store provider message IDs for webhook correlation:

```elixir
ReceiptStatus.mark_sent(receipt, %{
  "id" => provider_message_id,
  "status" => "queued"
})
```

### 3. Include source information

When creating receipts, include source type and ID for traceability:

```elixir
%{
  event_id: "orders.shipped",
  source_type: "Elixir.MyApp.Orders.Order",
  source_id: order.id,
  # ...
}
```

### 4. Respect user preferences

Always check preferences before delivery (AshDispatch does this automatically):

```elixir
# The PreferenceProvider is called before each delivery
config :ash_dispatch,
  preference_provider: MyApp.NotificationPreferences
```

## Next Steps

- [Configuration](configuration.md) - All configuration options including `send_now_authorizer`
- [Architecture](architecture.md) - Internal module documentation
- [User Preferences](user-preferences.md) - Implement notification opt-outs
- [Oban Configuration](oban-configuration.md) - Job queue setup
