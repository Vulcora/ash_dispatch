# Backlog

Design-level findings that change behavior across consumers (the internal apps and a client
integration) and therefore need deliberate work — not quick
fixes. Source: the cross-app integration audit 2026-08-10 run during the
a client migration. Small, safe bugs found in the same audit were
fixed directly in 0.5.2 (see CHANGELOG).

## 1. Retry semantics: Oban's own retries are inert for email

**Largely resolved in 0.5.6**, which absorbed a consumer-proven patch set:
`mark_sending` now accepts `:failed` as a source state (Oban backoff retries
work), and `RetryFailedDeliveries` moves the receipt to `:scheduled` BEFORE
enqueueing — the enqueue-first ordering silently dropped mails whenever the
worker won the race (17 dropped in one production deployment). On enqueue
failure the receipt is put back to `:failed` instead of stranding on
`:scheduled`.

**Double enqueueing resolved in 0.8.6:**
- The cron ran the `:retry` action — whose `EnqueueRetryJob` change enqueues
  a job — and then enqueued a second one itself. It now tells the action not
  to (`ash_dispatch_enqueue?: false` in the changeset context) and keeps its
  own enqueue, which it needs for the failure handling.
- `SendEmail` and `SendSMS` `unique` now cover `:retryable`, so a cron retry
  no longer lands beside the job Oban's own backoff is about to run.
- `retry_count`: only `:retry` increments it (`mark_failed` stopped in
  0.5.6); `test/workers/retry_accounting_test.exs` now pins both.

**Installer and queue resolved in 0.9.3:**
- `mix ash_dispatch.install` writes the Oban queues and both cron entries
  instead of printing them. It adds only what is missing: a queue size or a
  schedule the host chose is left alone, and running the installer twice
  changes nothing (it used to stop on "File already exists").
- The retry worker's queue is `config :ash_dispatch, retry_queue:`. The
  default stays `:default` in 0.9.x — moving it to `:emails` would stop the
  retries of a host whose Oban has no `:emails` entry for it, without notice,
  so that waits for 0.10.0.

## 2. ManualTrigger `:trigger` accepts arguments it ignores — RESOLVED in 0.8.6

The four options are dispatch options now (`Dispatcher.dispatch/4`). A
recipient override dispatches only email channels, renders each for its
first resolved recipient, creates one receipt to the override address without
a `user_id`, and records the replaced recipient and the actor in
`content.manual_override`. `skip_preferences` bypasses both opt-out gates and
is recorded the same way. The trigger also no longer generates the send
variables twice. Original finding kept below for context.

### Original finding

`recipient_email`, `audience`, `transport` and `skip_preferences` on the
`.Base` `:trigger` action are packed into the dispatch *variables* map and
never read by the send path: mail goes to whoever the resolver returns,
channels are not filtered, preferences are still enforced. Preview honors
them — so preview and trigger disagree about the recipient. mosis's admin
"send test to myself" button is built on exactly this and silently mails the
resolved recipient instead of the admin.

Fix: implement the four options for real (recipient override needs an
explicit, auditable bypass of the resolver) or remove the arguments.
Swedishspytours works around it by dispatching directly with an overridden
recipient in its own controller — that pattern could become a library
helper (`Dispatcher.dispatch_to/4`?).

## 3. Sensitive content retention — RESOLVED in 0.5.4

Shipped as `AshDispatch.Workers.ScrubSensitiveContent` + per-event
`metadata: [sensitive_content: true]` + `config :ash_dispatch,
:scrub_after_hours`. Consumers still need to schedule the cron entry and tag
their events. Original finding kept below for context.

### Original finding

Receipt-first stores full rendered bodies forever. For OTP codes and
password-reset links that means live secrets in the database, and there is
no redaction/opt-out (`store_content: false`, `redact_after: hours`) and no
retention/pruning at all for receipts or notifications. One consumer runs
an app-level scrub worker (blank bodies of its 2FA/reset events after 24h);
the other consumers store reset-link bodies indefinitely today.

Fix: per-event `metadata: [sensitive_content: true]` + a library-provided
scrub/retention worker, so app-level workarounds can be retired.

## 4. Ship a Resend webhook signature verifier — RESOLVED in 0.5.4

Shipped as `AshDispatch.WebhookHandlers.Resend.verify/3` (Svix HMAC,
constant-time compare, multi-signature, replay window). Consumers still need
to wire it into their controllers with a raw-body reader; a ready-made plug
remains open. Original finding kept below for context.

### Original finding

The webhook handler does no signature verification and the moduledoc's
example controller doesn't either. Of the four consumers, only
one consumer verifies (hand-rolled Svix HMAC in its controller);
one consumer's router even claims "verified by provider-specific signatures"
while verifying nothing, and two consumers expose unauthenticated
endpoints that mutate receipt state. A `AshDispatch.WebhookHandlers.
Resend.verify/2` (svix-id/timestamp/signature + raw body + secret, with
replay window) — or a plug — fixes every consumer with one upgrade.

## 5. Dead/declared-but-unused surface

- `should_send?/2` and `enrich_context/2` are behaviour callbacks nothing in
  the send path calls; `should_send_filter` DSL feeds the former.
- `recipient_filters` is documented as an app config key but the runtime
  reads `:audiences` — a phantom key with zero effect.
- Event `priority` is documented as persisted on the receipt; there is no
  such attribute (only in-app `metadata.priority`).
- `deduplicate_in_app` exists only in a stale comment.
- `mailer:` in the top-level example config is never read (real key:
  `swoosh_mailer`).

Fix: implement or delete, and align the docs.

## 6. `use AshDispatch.Setup` is a degraded second implementation — RESOLVED in 0.8.4

Rebuilt as a thin wrapper over `DeliveryReceipt.Base` instead of a hand-kept
copy, so there is one implementation again. It also turned out never to have
compiled: the resource body was spliced into the domain module instead of
being passed to `Module.create/3`, and it pointed `belongs_to :notification`
at the docs-only placeholder `AshDispatch.Resources.Notification`. It now
requires `:notification_resource`. Original finding kept below for context.

### Original finding

No `:slack` transport, constrained audiences, missing source/locale fields,
missing `get_by_provider_id`/`send_now`/`record_webhook_event`, and a
policy that authorizes every read. Deprecate it in favor of the Base
modules, like the legacy ManualTrigger resource (deprecated 0.5.2).

## 7. `list_events`' `user_id` argument is ignored

`ManualTrigger.Base` `:list_events` accepts `user_id` "to filter events
based on user state" and then passes `nil` to the helper.

## 8. Gettext-mode findings (2026-08-11 i18n audit)

The gettext path (catalog generator + `translate_content/2`) has no test
coverage at all and is undocumented in the CHANGELOG. Beyond the domain
bug fixed in `fix/gettext-domain-catalog`:

- mosis's PO→TS pipeline (`mix mosis.i18n.codegen` + `useT()`), the only
  consumer-side bridge, is generic (561 lines, zero ash_dispatch refs) and
  a candidate for extraction into a standalone `gettext → TypeScript`
  package. Known defects to fix at extraction: msgids flattened across
  domains (later domain silently wins), two interpolation dialects
  (`%{var}` vs `{{var}}`) in one catalog, and the full 31-locale 3 MB
  bundle loaded to select one locale.
- Dispatch msgids are emitted into mosis's frontend bundle but backend
  notification strings arrive already translated over the socket — the
  frontend copies are dead weight.
- The integration point for any such tool is Ash's generic
  `Spark.Dsl.Extension.codegen/1` callback — ash_typescript has no codegen
  hooks, so "an ash_typescript extension" is not actually possible today.

## 9. Raise the declared Elixir floor — RESOLVED in 0.9.0

`mix.exs` says `elixir: "~> 1.17"` since 0.9.0, and CI's
`compile-without-optional-deps` job runs on that floor. The CHANGELOG says so
under its own heading.

The full library update pass this was meant to travel with is not done: it
is still open for a later dependency round.

### Original finding

`mix.exs` said `elixir: "~> 1.15"`. That is true of ash_dispatch's own code,
and of an app that pins an older Ash — but **Ash 3.33 does not compile on
1.15**: it uses `Duration` (Elixir 1.17) while declaring `~> 1.11`. So a
default install needed 1.17, and the declared floor no longer described
what `mix deps.get` produces.

## 10. Notification centre and per-person preferences — RESOLVED in 0.9.0

What an app needs for a bell, a notification list and a settings page, which
until 0.9.0 every consumer built itself:

- `Dispatcher.dispatch/4` `:actor` fills `context.user`, so `exclude_actor`
  works for manual events; the actor's id is on every receipt (`actor_id`).
  `:tenant` fills `context.tenant`, for manual and action-triggered events.
- `recipient_fields` `id:` links a map recipient to its user.
- The checker gets `:tenant`, `:recipient` and `:event_default`;
  `metadata: [user_configurable: false]` is never gated.
- `AshDispatch.Resources.Preference.Base` + `AshDispatch.UserPreference.Resource`:
  person > tenant > event default, one query per dispatch through the new
  `prefetch/2` callback, and introspection for a settings screen
  (`configurable_events/1`, `settings/3`, `put/3`, `clear/2`).
- `Notification.Base`: `category`, `tenant`, `seen_at`, `archived_at`,
  `:unread`, `:unread_count`, `mark_all_as_read` that carries the actor
  (and `NotificationLoader.mark_all_as_read/2` passing it on).
- `AshDispatch.Phoenix.LiveView`: on_mount hook with a live unread count.

Later, if asked for:

- A standalone event dispatched by the notifier (no DSL `event` block) still
  finds `context.user` in `data` rather than taking the action's actor, as it
  always has; switching it would change what such an event module reads as
  its subject.
- ~~The receipt carries `actor_id` but no `tenant`; per-tenant receipt reports
  read it through the source record for now.~~ **Resolved in 0.9.4:**
  `tenant_column: true` on `DeliveryReceipt.Base` adds the column, and
  `multitenancy: :context` puts the receipts in the tenant's own schema
  instead. See the Tenancy guide.
- `Preference.Base`'s upsert relies on `NULLS NOT DISTINCT` (Postgres 15+);
  `UserPreference.Resource.put/3` updates an existing row itself, so it also
  works on data layers without it.
