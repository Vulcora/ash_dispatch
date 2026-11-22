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
# Mark as sending (worker starting delivery). Not legal from `sending`: that
# refusal is the mutex that stops two jobs sending one receipt.
Ash.update(receipt, :mark_sending)

# Reclaim a receipt this job's own earlier attempt left in `sending`
# (`sending` → `sending`, since 0.9.4). Use `ReceiptStatus.claim/2`, which
# decides between this and `mark_sending` for you.
Ash.update(receipt, :resume_sending)

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
# => "Acme <noreply@acme.test>"
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
- Sweeps receipts stranded in `scheduled` on the same pass (see below)

## A receipt for a send the library did not make

Every installation has a send that does not go through the dispatcher: a
provider's own SDK, a one-off script, a confirmation written before this
library arrived, a transport it has no backend for. Those leave no receipt,
and a missing receipt is not a neutral gap — it reads as "nothing was sent".
One installation measured ninety-two of ninety-six cases where a recipient had
been reached and no letter existed to prove it.

`AshDispatch.Receipts.record/2` writes the receipt without sending anything:

```elixir
AshDispatch.Receipts.record(
  %{
    event_id: "bookings.reminder",
    transport: :sms,
    audience: :user,
    recipient: "+46701234567",
    user_id: user.id,
    content: %{message: text},
    source_type: "Booking",
    source_id: booking.id
  },
  {:sent, %{id: provider_message_id}}
)
```

| Outcome | Receipt |
|---|---|
| `{:sent, response}` | `sent`, with `provider_id` from the response — so the delivery webhook finds it exactly as it finds ours |
| `{:skipped, reason}` | `skipped`, with the reason |
| `{:error, reason}` | `failed_permanent`, **not** `failed`: a `failed` receipt is what the retry sweep picks up, and it would send our rendering of a letter we never composed. `retry?: true` if you want it to |

Nothing is delivered, no job is enqueued, no notification is written. Any key
the receipt resource does not accept is dropped rather than raised on, and
`tenant:` is the schema the row is written to.

## Why a letter was not sent

`error_message` is written for a person to read, and this library rewords it
whenever the prose can be clearer. Counting it therefore means matching
substrings against sentences that are free to change — which is what every
host that wanted "how much did we hold back last month, and why" ended up
doing.

Since 0.9.4 the library writes a code beside the sentence, in
`content["reason_code"]`: one of `AshDispatch.Reason.codes/0`, with `:other`
for a reason that came from a backend of your own, a provider's message, or a
transport you wrote. The sentence is unchanged and still says more.

```elixir
AshDispatch.Reason.of(receipt)
#=> :user_opted_out
```

`of/1` answers for a receipt written before 0.9.4 too, by classifying the
sentence — the substring matching, done once, by the library that wrote the
sentences. In SQL the code is a JSONB lookup, so there is nothing to migrate
and nothing to backfill:

```sql
SELECT content->>'reason_code' AS reason, count(*)
FROM delivery_receipts
WHERE status IN ('skipped', 'failed_permanent')
GROUP BY 1 ORDER BY 2 DESC;
```

Rows written before 0.9.4 answer `NULL` there; `of/1` still classifies them.
The list is closed on purpose: a code meaning "some other thing" is worth
nothing to count, so a new reason gets a new code in a new release rather
than being folded into `:other`. See `AshDispatch.Reason` for the table.

## Stranded receipts

Two statuses promise that something is in flight, and something can die
holding either of them.

**`scheduled`** says a job is coming. The sweep checks whether one actually
is: past a grace period a receipt is handed back to the retry machinery, and
past a staleness ceiling it is closed rather than delivered months late. This
is on by default and has been since 0.9.0.

**`sending`** says the provider is being called right now. A node that goes
down between `mark_sending` and the provider leaves the receipt there, and
until 0.9.4 nothing looked at it: the message was lost without a trace.
Oban's lifeline covers the case where the *job* survives — the next attempt
reclaims the receipt (`AshDispatch.ReceiptStatus.claim/2`) and sends it — but
not a job that was pruned, cancelled or discarded mid-send.

What makes `sending` different is that **we do not know whether the provider
got the message**, so resending is an at-least-once delivery and the
recipient may get the same letter twice. That is your call, not the
library's:

```elixir
config :ash_dispatch,
  stranded_sending: :ignore   # the default
```

| Mode | What the sweep does with a stranded `sending` receipt |
|---|---|
| `:ignore` | Nothing. Exactly what every release before 0.9.4 did |
| `:close` | `failed_permanent`, with a reason saying the outcome is unknown. **Nothing is sent twice, and the silent loss stops being silent** |
| `:rescue` | `failed`, so the retry machinery takes over. At-least-once: a letter the provider already accepted may go out again |

`:close` is the one to pick if you do not want to think about it: it makes the
loss visible without risking a duplicate. The grace period
(`:stranded_stuck_after_minutes`) applies under both, so a send that is
merely in progress is never touched.

See `AshDispatch.Workers.Stranded`.

## Best Practices

### 1. Use ReceiptStatus helper

For status updates in custom workers, use the centralized helper. Claim the
receipt with `claim/2` rather than `mark_sending/1`: it keeps the mutex that
stops two jobs sending one receipt, *and* lets your worker's own interrupted
attempt finish the job instead of completing green on a letter nobody sent.

```elixir
case AshDispatch.ReceiptStatus.claim(receipt, attempt: job.attempt) do
  {:ok, receipt} -> deliver(receipt)
  # Another job has it. Nothing was lost; finish as a success.
  :duplicate -> :ok
  {:error, reason} -> {:error, reason}
end
```

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

Preferences are checked before delivery, but note WHICH key does it — the
two are not the same (see [Configuration](configuration.md#user-preferences)):

```elixir
config :ash_dispatch,
  # Consulted by every transport before delivery:
  user_preference: MyApp.NotificationPreferences,
  # Consulted by the email worker and manual triggers only:
  preference_provider: MyApp.LegacyPreferences
```

A receipt skipped by the transport gate carries
`error_message: "user_opted_out"`; one skipped by the email worker's provider
path carries `"User opted out of this email category"`. A count of opt-outs
has to know about both.

## Webhook Signature Verification

Resend webhooks mutate receipt state (opened/bounced/delivered), so verify
the Svix signature before handing the payload to `process_webhook/1`:

```elixir
case AshDispatch.WebhookHandlers.Resend.verify(raw_body, headers, secret) do
  :ok -> AshDispatch.WebhookHandlers.Resend.process_webhook(params)
  {:error, _} -> # respond 400
end
```

`raw_body` must be the request body exactly as received — cache it before
your JSON parser runs. See `AshDispatch.WebhookHandlers.Resend.verify/4`.

## Sensitive Content Retention

Receipts store full rendered bodies, which for OTP codes and password-reset
links means live secrets in the database. Declare such events with
`metadata: [sensitive_content: true]` and schedule
`AshDispatch.Workers.ScrubSensitiveContent` (cron): bodies older than
`config :ash_dispatch, :scrub_after_hours` (default 24, terminal receipts only;
any other status at `:scrub_stranded_after_hours`, default 168) are blanked while
recipient, subject, status and delivery timestamps stay intact. `:failed`
receipts are left for the retry path first.

## Next Steps

- [Configuration](configuration.md) - All configuration options including `send_now_authorizer`
- [Architecture](architecture.md) - Internal module documentation
- [User Preferences](user-preferences.md) - Implement notification opt-outs
- [Oban Configuration](oban-configuration.md) - Job queue setup
