# Previews and testing

Three tools, one idea: what you look at before a mail goes out must be what
the recipient gets.

- `AshDispatch.Preview` renders any event as it would be sent, without
  sending it — for an admin page, a "send a test to myself" button, a snapshot.
- `AshDispatch.Test.assert_all_render/1` renders every letter your app can
  send and fails on any that would go out broken — a test on one line.
- `strict_templates: true` refuses, at build time, the template expressions
  that go out as raw text.

## Previewing

```elixir
# The catalogue: one row per event × channel (transport, audience, variant)
AshDispatch.Preview.events()
#=> [%{event_id: "orders.created", transport: :email, audience: :user,
#      variant: nil, module: MyApp.Orders.Events.Created.Event, ...}, ...]

# From the event's sample data, reproducibly
{:ok, [letter]} = AshDispatch.Preview.render("orders.created", :sample, seed: 42)

# From a stored record — the event's own load and prepare_data/2 included
{:ok, letters} = AshDispatch.Preview.render("orders.created", {:record, order.id})

# From data of your own, as you would pass it to Dispatcher.dispatch/3
{:ok, letters} = AshDispatch.Preview.render("orders.created", %{order: order})
```

Each result is an `AshDispatch.Preview.Rendered`. For email it carries the
envelope the backend would receive: `to`, `from`, `reply_to`, `subject`,
`html_body`, `text_body`, `attachments` and `headers`. Filter with
`transport:`, `audience:` and `variant:`, or pass a row from `events/0`
straight to `render/3`. `locale:` renders in a given locale.

### The same path as the send

There is no preview renderer. `render/3` opens the event the way its send
opens it (`Dispatcher.prepare/3`, or the notifier's preparation for an
action-triggered event), resolves the recipient the way the dispatcher does,
renders through the function that builds the receipt, and builds the envelope
with the email transport's job args and the `SendEmail` worker's backend
params. The library's own parity test sends a letter for real and compares it
with its preview field by field.

What it leaves out is everything with a side effect: no receipt, no job, and
never `generate_send_variables/2` — that is where events mint reset tokens
and invitation links, and a preview must not create any. A template that
prints such a variable renders the one you pass in `variables:`. For a page
that must not touch the database at all, pass `read_records?: false` and
`resolve_recipients?: false`.

What a preview cannot show is what is only decided at send time: whether
`should_send?/2` lets it through, the recipient's preferences, and the
`skip_if_read` policy.

### Seeds

A `:sample` render seeds the process's `:rand` with `seed:` for the duration
of the render, so the same seed gives the same letter — put the seed in a URL
and the link shows what its sender saw. Without one, a seed is drawn and
returned in `Rendered.seed`.

An event can take the seed itself:

```elixir
@impl true
def sample_data(seed: seed) do
  %{order: MyApp.Factory.order(seed)}
end
```

`sample_data/1` falls back on `sample_data/0`, so events that only define
that keep working — and data they draw from `:rand` is reproducible anyway.

## Sending a test to yourself

The ManualTrigger `:trigger` action's `recipient_email` sends the letter to
that address instead of the resolved recipient. The override is total: only
email channels go out, each renders for its first resolved recipient and
creates exactly one receipt — to your address, without a `user_id` — and
`receipt.content.manual_override` records whom it replaced. The real
recipient is never written to.

The same is available directly:

```elixir
AshDispatch.Dispatcher.dispatch("orders.created", %{order: order}, %{},
  recipient_email: "me@example.com",
  actor: current_user
)
```

`audience:` and `transport:` (or `channels:` on `dispatch/4`) select the
channels; `skip_preferences: true` bypasses the opt-out, and is recorded
the same way.

## "Every mail renders"

```elixir
defmodule MyApp.MailsRenderTest do
  use MyApp.DataCase, async: true

  test "every mail renders" do
    assert AshDispatch.Test.assert_all_render(seeds: 25) == 42
  end
end
```

It renders every row of `events/0` from sample data, once per seed, and fails
— listing each finding with event, channel and seed — when a letter could not
be rendered, an email has an empty subject or no body, or the output still
contains template source (`<%`, `{@`, `#{`, `{if `, `{for `, `{case `, …) or
`TODO`. Add markers of your own with `forbid:`.

Assert on the returned count, exactly. A test that is green because nothing
was rendered is the failure it exists to prevent; a hard-coded number goes red
when an event loses a channel or a template instead of quietly checking less.

`render_all/1` returns the results instead of failing, for your own checks
(length of the subject, absolute links, `lang` attribute, …).

## Time, and whose clock the library writes

A host that controls time through a module of its own — one `MyApp.Clock`
everything calls, frozen or travelled in tests — controls the timestamps this
library writes **from Elixir** since 0.9.4-rc.4, and still does not control
the two Ash fills. The difference matters before a test asserts on either.

### Giving the library your clock

```elixir
config :ash_dispatch, clock: {MyApp.Clock, :utc_now, []}
```

Unset, it is `DateTime.utc_now/0` — what every release before 0.9.4-rc.4 did,
and what a host that sets nothing still gets. A bare module means its
`utc_now/0` (`clock: MyApp.Clock`), and any 0-arity function is accepted
(`clock: &MyApp.now/0`).

Everything in the "this library" row of the table below goes through it:
`occurred_at`, `sent_at`, `read_at`, `seen_at`, `archived_at`,
`last_retry_at`, the cut-offs `RetryFailedDeliveries` and
`ScrubSensitiveContent` compare a receipt against, the staleness bounds in
`AshDispatch.Workers.Stranded`, `AshDispatch.Context`'s `:now` (and therefore the
broadcast payload's timestamp), a webhook envelope's `sent_at` and a Resend
event's `webhook_received_at`.

### Freezing time in a test

```elixir
defmodule MyApp.FrozenClock do
  @moduledoc "A clock a test can set. One agent, one instant."

  def start_link(at), do: Agent.start_link(fn -> at end, name: __MODULE__)
  def utc_now, do: Agent.get(__MODULE__, & &1)
  def travel(to), do: Agent.update(__MODULE__, fn _ -> to end)
end
```

```elixir
test "a notification is stamped with the time the test chose" do
  frozen = ~U[2026-03-01 12:00:00.000000Z]
  start_supervised!({MyApp.FrozenClock, frozen})
  Application.put_env(:ash_dispatch, :clock, {MyApp.FrozenClock, :utc_now, []})
  on_exit(fn -> Application.delete_env(:ash_dispatch, :clock) end)

  {:ok, notification} =
    MyApp.Notifications.Notification
    |> Ash.Changeset.for_create(:create, %{user_id: user.id, title: "t", message: "m"})
    |> Ash.create()

  assert notification.occurred_at == frozen
end
```

The same clock decides the retry cut-off, so a test can put a receipt an hour
in the "past" and let `RetryFailedDeliveries` find it without waiting:

```elixir
MyApp.FrozenClock.travel(DateTime.add(frozen, 3600, :second))
assert :ok = perform_job(AshDispatch.Workers.RetryFailedDeliveries, %{})
```

Two things it does **not** freeze, and one of them will fail an equality
assertion:

- **`inserted_at` and `updated_at`.** See below: they are Ash's, not this
  library's, and moving them is 0.10.0 (BACKLOG 13).
- **The Resend webhook's timestamp tolerance.** That compares our wall clock
  against the sender's to reject a replayed signature, so it stays on
  `System.system_time/1` on purpose. Pass `now:` to
  `AshDispatch.WebhookHandlers.Resend.verify/4` in a test instead.

### What the columns are

Every timestamp in the library's own resources is **`utc_datetime_usec`**:
`inserted_at` and `updated_at` on all three (`DeliveryReceipt.Base`,
`Notification.Base`, `Preference.Base`), and so are `occurred_at`, `read_at`,
`seen_at`, `archived_at`, `sent_at`, `delivered_at`, `failed_at`,
`bounced_at`, `last_retry_at` and the rest.

In Postgres that is `timestamp` **without** time zone, holding UTC by
convention. A host that uses `timestamptz` everywhere else has these tables as
the exception. They are not wrong — a `utc_datetime_usec` is unambiguous
because it is always UTC — but they do not join cleanly against a `timestamptz`
column without a cast, and `AshPostgres.Timestamptz` is not what the bases
declare.

### Where the value comes from

`inserted_at` and `updated_at` carry a **database default** in the generated
migration:

```elixir
add :inserted_at, :utc_datetime_usec, null: false, default: fragment("(now() AT TIME ZONE 'utc')")
```

That default is a safety net for a row inserted by something other than Ash.
It is not where the value normally comes from: Ash fills both attributes from
its own `&DateTime.utc_now/0` while it builds the changeset, so what reaches
the database is the **BEAM's clock**, in the process that did the write, and
the column default never fires.

Three clocks are involved, and one of them is now yours:

| Written by | Clock | Can a host supply it? |
|---|---|---|
| `occurred_at`, `sent_at`, `read_at`, `seen_at`, `archived_at`, `last_retry_at`, the retry/scrub/stranded cut-offs, `Context`'s `:now` | `AshDispatch.Clock` | **yes**, since 0.9.4-rc.4 |
| `inserted_at`, `updated_at` | the BEAM, through Ash's `timestamps` macro | no — 0.10.0, BACKLOG 13 |
| the column DEFAULT, for a non-Ash `INSERT` | the database | no |

`inserted_at` and `updated_at` are `writable?: false`, so an action cannot
accept them either.

Why those two are not on the clock is worth knowing, because it looks
arbitrary: Ash's `timestamps` macro defaults them to the literal capture
`&DateTime.utc_now/0`, and that exact value is what ash_postgres matches on to
write `DEFAULT (now() AT TIME ZONE 'utc')` into the migration. Anything else
there makes the next `mix ash.codegen` in *every* host emit an
`ALTER COLUMN … DROP DEFAULT`, and a patch release may not require a
migration. `occurred_at` could move because its default was already an
`{m, f, a}` tuple, which ash_postgres maps to no column default either way.

### What to do in a test

With a clock configured, assert on the instant you chose — see *Freezing time
in a test* above.

Without one, do not assert on an exact instant in a library-written timestamp.
Assert on the ordering or the window:

```elixir
before = DateTime.utc_now()
AshDispatch.Dispatcher.dispatch("orders.created", %{order: order})
receipt = read_the_receipt()

assert DateTime.compare(receipt.inserted_at, before) in [:gt, :eq]
```

That is still the rule for `inserted_at` and `updated_at` whatever you
configure: a test that freezes time cannot pin those two, and a strict
equality against a frozen instant fails.

`AshDispatch.Context`'s `:now` can also be set for one dispatch, which is the
narrower tool when only that dispatch should see a different time:

```elixir
AshDispatch.Dispatcher.dispatch("orders.created", %{order: order}, %{}, now: frozen)
```

Moving the columns to `timestamptz` is a migration and therefore 0.10.0;
BACKLOG 13 has both halves.

## Strict templates

ash_dispatch renders `.html.heex` templates with EEx, after turning
`{@assign}` and `attr={...}` into EEx tags. They look like HEEx, which is what
makes the rest dangerous: `#{...}` in body position is three characters that
go out in the mail (and `mix format` writes it for you, from
`#<%= @number %>`), and a `{if ...}` the preprocessor does not convert goes out
as its own source code — while the rest of the mail looks right.

```elixir
config :ash_dispatch, strict_templates: true
```

With it, the `:ash_dispatch` compiler fails the build on such a template, with
the file and line, and `TemplateResolver` refuses to render one. Off by
default. Write `<%= if @x, do: "a", else: "b" %>`, or compute the value
in `prepare_template_assigns/2` and print it with `{@value}`.

## Extra headers

`headers/2` on the event adds headers to its emails. The common one is
`X-Entity-Ref-ID`, which keeps Gmail from threading every "Your booking is
confirmed" into one conversation:

```elixir
@impl true
def headers(context, %Channel{transport: :email}) do
  %{"X-Entity-Ref-ID" => context.data.booking.id}
end

def headers(_context, _channel), do: %{}
```

They are stored in the receipt (a retry keeps them), passed to the backend as
`:headers`, and shown by the preview.
