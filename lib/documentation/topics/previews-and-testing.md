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
everything calls, frozen or travelled in tests — does not control the
timestamps this library writes. That is worth knowing before a test asserts on
one.

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
the column default never fires. The same is true of every other timestamp
above — `occurred_at` defaults to `DateTime.utc_now()`, and `sent_at`,
`read_at`, `seen_at`, `archived_at` and `last_retry_at` are set by changes
that call `DateTime.utc_now/0` directly.

So there are two clocks involved and neither of them is yours:

| Written by | Clock | Can a host supply it? |
|---|---|---|
| `inserted_at`, `updated_at` | the BEAM, through Ash's `timestamps` macro | no |
| `occurred_at`, `sent_at`, `read_at`, `seen_at`, `archived_at`, `last_retry_at`, … | the BEAM, in this library | no |
| the column DEFAULT, for a non-Ash `INSERT` | the database | no |

`inserted_at` and `updated_at` are `writable?: false`, so an action cannot
accept them either.

### What to do in a test

Do not assert on an exact instant in a library-written timestamp. Assert on
the ordering or the window:

```elixir
before = DateTime.utc_now()
AshDispatch.Dispatcher.dispatch("orders.created", %{order: order})
receipt = read_the_receipt()

assert DateTime.compare(receipt.inserted_at, before) in [:gt, :eq]
```

If your test freezes time in your own clock module, the library's rows are
still stamped with the real one, and a strict equality against your frozen
instant fails. That is the finding behind this section, not a defect: the
library never claimed to take its time from anywhere else.

One seam does exist today. `AshDispatch.Context` carries `:now`, settable per
dispatch, and the broadcast transport's payload timestamp uses it:

```elixir
AshDispatch.Dispatcher.dispatch("orders.created", %{order: order}, %{}, now: frozen)
```

Nothing that is *persisted* reads it yet. Widening that seam to the values the
library writes from Elixir is BACKLOG 13; moving the columns to `timestamptz`
is a migration and therefore 0.10.0.

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
