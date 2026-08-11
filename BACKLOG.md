# Backlog

Design-level findings that change behavior across consumers (mosis, siteflow,
magasin, swedishspytours) and therefore need deliberate work — not quick
fixes. Source: the cross-app integration audit 2026-08-10 run during the
swedishspytours migration. Small, safe bugs found in the same audit were
fixed directly in 0.5.2 (see CHANGELOG).

## 1. Retry semantics: Oban's own retries are inert for email

`SendEmail` has `max_attempts: 5`, but after the first failure the receipt is
`:failed` and `mark_sending` has no `:failed -> :sending` transition — the
`NoMatchingTransition` branch treats attempts 2–5 as duplicate jobs and
returns `:ok` without sending. The ONLY working retry path is the
`RetryFailedDeliveries` cron, which consumers must remember to schedule (all
four apps now do, but nothing enforces it).

Options, not mutually exclusive:
- Add `transition(:mark_sending, from: [:failed], to: :sending)` so Oban's
  backoff retries work — but design the interaction with the cron first:
  the cron's `unique` check on SendEmail does not cover the `:retryable`
  state, so cron + in-flight-backoff can double-enqueue.
- Or drop `max_attempts` to 1 and make the cron the documented single retry
  path, so the config stops promising retries that never happen.
- Either way: `mix ash_dispatch.install` should add the cron entry, and the
  retry worker should run in `:emails` (a queue integrators already must
  define) instead of `:default`.

## 2. ManualTrigger `:trigger` accepts arguments it ignores

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

## 3. Sensitive content retention

Receipt-first stores full rendered bodies forever. For OTP codes and
password-reset links that means live secrets in the database, and there is
no redaction/opt-out (`store_content: false`, `redact_after: hours`) and no
retention/pruning at all for receipts or notifications. Swedishspytours runs
an app-level scrub worker (blank bodies of its 2FA/reset events after 24h);
mosis/siteflow/magasin store reset-link bodies indefinitely today.

Fix: per-event `metadata: [sensitive_content: true]` + a library-provided
scrub/retention worker, so app-level workarounds can be retired.

## 4. Ship a Resend webhook signature verifier

The webhook handler does no signature verification and the moduledoc's
example controller doesn't either. Of the four consumers, only
swedishspytours verifies (hand-rolled Svix HMAC in its controller);
siteflow's router even claims "verified by provider-specific signatures"
while verifying nothing, and both siteflow and magasin expose unauthenticated
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

## 6. `use AshDispatch.Setup` is a degraded second implementation

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
