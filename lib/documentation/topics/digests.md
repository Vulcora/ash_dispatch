# Digests

A person who gets five emails in two minutes — a status change, three
comments, a reassignment — reads none of them carefully. A digest sends
them as one: a few minutes after the last, or once a day, or once a week.

Digests are **per recipient** (one letter per person, listing what happened
to *them*) and **receipted**: the digest has a `DeliveryReceipt` of its own,
and every email in it keeps its own receipt, marked `:digested` and pointing
at the digest. Nothing about how an email is written changes.

## Opting a channel in

Give an email channel a digest time instead of a delay:

```elixir
event :commented,
  trigger_on: :create,
  module: MyApp.Events.Commented,
  channels: [
    [transport: :email, audience: :user, time: {:digest, {:quiet, 300}}],
    [transport: :in_app, audience: :user]
  ]
```

or, in an event module:

```elixir
def channels(_context) do
  [%AshDispatch.Channel{transport: :email, audience: :user, time: {:digest, {:quiet, 300}}}]
end
```

Only email channels can be digested. The in-app notification is unaffected:
it is written at once, as before.

## Windows

| Window | Goes out |
| --- | --- |
| `{:quiet, seconds}` | `seconds` after the newest email for this person, but never later than `digest_max_wait` (default 1800) after the first |
| `{:quiet, seconds, max_wait}` | the same, with its own ceiling |
| `:daily` | at `digest_send_at` in `digest_time_zone` |
| `:weekly` | the same, on `digest_week_day` |

`{:quiet, …}` is for bursts. Each new email moves the send time forward,
so a conversation in progress becomes one email when it pauses — and the
ceiling makes sure a steady trickle still goes out.

```elixir
config :ash_dispatch,
  digest_max_wait: 1800,
  digest_send_at: ~T[07:00:00],
  digest_time_zone: "Europe/Stockholm",  # needs a time zone database
  digest_week_day: 1                      # Monday
```

## One email is not a digest

When the window is due and only **one** email is waiting, it is sent as
itself — the letter the event wrote, with its own subject — through the
ordinary send path (`:batched` → `:scheduled` → `:sent`). Only two or more
become a digest. A person who gets a single comment in a quiet hour gets
the comment, not "1 update".

## Receipts

```
pending → batched → scheduled → sending → sent        (alone in its window)
                  ↘ digested                          (went out in a digest)
                  ↘ skipped                           (read in the app first,
                                                       with policy: :skip_if_read)
```

The digest's own receipt has the event id `"ash_dispatch.digest"`
(`config :ash_dispatch, digest_event_id:`), the recipient's `user_id`, and
`content["digest"]["entries"]`: the receipt ids it holds. Each entry has
`content["digest"]["receipt_id"]`: the digest it went out in. Retries,
webhooks and "send now" work on the digest receipt like on any email.

Count `:sent` receipts and you count emails that reached an inbox, once
each — `:digested` is how the others are accounted for.

"Send now" on a `:batched` receipt sends that email on its own and takes it
out of the digest.

## The person's say

A preference checker (`config :ash_dispatch, user_preference:`) may
implement `c:AshDispatch.UserPreference.user_digest_mode/2`:

```elixir
@impl true
def user_digest_mode(user_id, opts) do
  case MyApp.Settings.mail_mode(user_id, opts[:tenant]) do
    :immediate -> :off       # each email at once
    :bundled -> :default     # the channel's window
    :daily -> :daily
  end
end
```

It is asked only for channels that opted in, after `c:AshDispatch.UserPreference.user_allows?/4` has
let the email through. A login link or an order confirmation without a
digest time is never delayed, whatever a person chose. To let a person
switch an email off entirely, answer `false` from `c:AshDispatch.UserPreference.user_allows?/4` as
before; a digest mode is about *when*, never *whether*.

## What is never batched

- An event with `metadata: [sensitive_content: true]`. A reset link must
  not wait, and must not sit next to other letters.
- An event with attachments of its own (`attachments/2`). They live only in
  the send job's args, and a batched email has no job until it is released.
  The app-wide `default_email_attachments` (an inline logo) are fine: they
  are added to the released or digest email.
- A manual dispatch with a recipient override (a test send).

These are sent at once, as if the channel had no digest time.

## The letter

What each email contributes is `c:AshDispatch.Event.digest_item/2`, stored
on its receipt when it is batched:

```elixir
def digest_item(context, _channel) do
  %{
    title: "Comment on #{context.data.ticket.title}",
    summary: context.data.comment.body,
    url: ticket_url(context.data.ticket),
    label: "Open the ticket"
  }
end
```

Without it, the item is the email's subject and the first paragraph of its
text body.

The digest is rendered by `AshDispatch.DigestRenderer`. The default is a
plain English list ("3 updates"). A host with a mail design of its own
renders it in that design:

```elixir
config :ash_dispatch, digest_renderer: MyApp.DigestRenderer
```

The renderer gets the items in the order the emails were written, and
returns `:subject`, `:html_body`, `:text_body` and optionally `:from` and
`:reply_to` (otherwise the first email's).

## Running it

Nothing to add to the crontab. Each batched email schedules an
`AshDispatch.Workers.FlushDigests` job for its recipient at the time the
window is due (unique per recipient, window and tenant; a newer email moves
the job instead of adding one). `RetryFailedDeliveries`, which a host
already runs, sweeps for overdue groups on every run — so a lost job delays
a digest by one retry interval at most. A host that wants a tighter bound
can schedule `FlushDigests` on its own; without a recipient it sweeps, and
it fans out per tenant like the other cross-tenant workers.

The jobs run in the `:emails` queue (`config :ash_dispatch, digest_queue:`).

## Testing

```elixir
test "two comments in a row become one email" do
  comment!(ticket)
  comment!(ticket)

  AshDispatch.Test.flush_digests()

  assert [%{subject: "2 updates"}] = sent_emails()
end
```

`AshDispatch.Test.flush_digests/1` sends everything that is waiting,
whatever its window. To test the timing itself, call
`AshDispatch.Digest.flush/4` with `now:`.
