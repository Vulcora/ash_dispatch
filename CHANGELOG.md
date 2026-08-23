# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.6.7] - 2026-08-23

### Added

- **The resource bases accept `notifiers:`.** They already accepted
  `extensions:`, and the omission was arbitrary — a notifier is how you
  observe what a resource did without touching how it does it.

  Without it, a consumer wanting to react to receipt transitions has to reach
  for a change instead, and a non-atomic change forces `require_atomic? false`
  onto **every update action in the base** — actions the consumer cannot edit.
  That is a compile error with no way out from the consuming app.

  Two lines in each of `DeliveryReceipt.Base` and `Notification.Base`, both
  defaulting to `[]`, so nothing changes for anyone who does not pass the
  option.

## [0.6.6] - 2026-08-23

### Fixed

- **A receipt can no longer strand in `:scheduled` unnoticed.** That status
  promises a job is coming; nothing ever checked whether one was. A receipt
  whose job died, was pruned, or never enqueued sat there permanently — the
  retry sweep queries `status == :failed`, so it never looked, and no surface
  counted it.

  One production deployment carried **17 such receipts across six months**:
  four order confirmations (two to a customer, not staff), four reseller
  applications and nine product announcements. All showed a provider 429, all
  were moved to `:scheduled` by a retry, none were seen again. The underlying
  race was fixed in 0.5.6; what remained was that nothing recovers the
  receipts already stranded, or any stranded by a future crash or deploy.

  `RetryFailedDeliveries` now sweeps `:scheduled` before its ordinary pass,
  with three outcomes (see `AshDispatch.Workers.Stranded`):

  | age | outcome |
  |---|---|
  | under the grace period | left alone — `:scheduled` is a legitimate transient state |
  | past grace, under the ceiling | moved to `:failed`, so the existing retry machinery takes over |
  | past the ceiling | `:failed_permanent` with a reason — **never sent** |

  The ceiling exists because delivering a January order confirmation in
  August is worse than silence: the recipient has to work out whether
  something went wrong. The invisible debt is the defect, not the unsent
  mail.

  Configurable via `:stranded_stuck_after_minutes` (default 30) and
  `:stranded_stale_after_hours` (default 24). A contradictory configuration
  where the ceiling falls below the grace period resolves to leaving receipts
  alone — never touching one that may still be in flight is the stronger
  safety property, since a double-sent mail cannot be recalled.

  **This acts on existing data on first run.** A consumer holding stranded
  receipts it still wants delivered should raise
  `:stranded_stale_after_hours` before upgrading.

  The decision function is covered by unit tests; the sweep's database
  plumbing is not, for the harness reasons recorded under 0.6.5.

## [0.6.5] - 2026-08-21

### Added

- **The recipient is in the context.** `do_build_receipt_content/4` runs once
  per recipient and has always had it in scope, but nothing downstream could
  see it: `prepare_template_assigns/2` receives `(context, channel)`, and
  template assigns were built from that return value plus
  `Context.template_assigns/1`. Greeting someone by name was impossible
  without reaching outside the render path.

  It now goes into `context.variables`, which is the one place that reaches
  **both** consumers — `Context.template_assigns/1` merges variables into the
  assigns a template sees, and the callback can read
  `context.variables[:recipient]` to PRECOMPUTE per-recipient values.

  That second half is the point. Exposing it only in the final assigns would
  have forced consumers to branch inside templates, which is exactly what a
  precomputed-assigns convention exists to prevent.

  `Map.put_new/3`, so an event that already resolves a richer recipient shape
  keeps its own. Purely additive: a context key nothing reads changes no
  output, and an event that never mentions the recipient renders
  byte-for-byte as before. `subject/2` still receives no recipient — a
  personalised subject line needs a callback signature change and is not part
  of this release.

  **Not covered by a test in this repo.** The suite has no harness for a full
  dispatch-to-receipt flow: no application-level `recipient_fields`, no
  configured `delivery_receipt_resource`, and further gaps behind those. An
  attempt to build one was abandoned as larger than the change it would
  guard. The behaviour is exercised end-to-end by magasin's mailing
  byte-identity test, which compares a preview rendered for a chosen
  recipient against what that recipient actually receives.

## [0.6.4] - 2026-08-18

Bug fixes in the delivery path, plus additive facades over machinery that
already existed. No behaviour changes for any existing consumer: every new
option defaults to exactly what the previous releases did.

### Fixed
- **User preferences are evaluated per receipt, not per context user.**
  The `:email` and `:in_app` transports asked
  `UserPreference.allows?(context, channel, event_config)` — a question
  about the user on the *context*, i.e. the event's subject. But a receipt
  is one recipient, so on any fan-out (one event, N receipts) that single
  verdict was applied to all N: one customer's opt-out silenced the whole
  send, and one customer's opt-in delivered to people who had opted out.
  Consumers implementing `user_allows?/4` never saw more than one user id
  per event and had no way to notice.

  Both transports now call the new `allows_receipt?/4`, which reads
  `receipt.user_id`. Receipts without a user id (external addresses,
  webhook targets) keep delivering unasked.

- **`{:at, %DateTime{}}` channel times are honored.** `normalize_time/1`
  accepted them, the `time` type documented them and
  `Channel.calculate_delay/1` knew how to compute them — but the email
  transport matched only `{:in, seconds}` and let everything else fall
  into a catch-all `0`, so an absolute-time channel sent IMMEDIATELY,
  silently (and `calculate_delay/1` had zero call sites). The delay is now
  computed from the datetime, clamped at 0 so a past time means "now".
  `{:in, seconds}` is unchanged.

### Added
- **`AshDispatch.preview/3`** — the preview engine behind ManualTrigger,
  exposed as a plain function. Renders subject/HTML/text for each channel
  of an event without delivering:

      AshDispatch.preview("orders.created", %{order_id: order.id},
        transport: :email, audience: :user)
      #=> {:ok, [%{subject: …, html_body: …, text_body: …, recipient: …}]}

  Options: `:audience`, `:transport`, `:actor`, `:recipient_email` (which
  only changes the displayed recipient — preview never sends).

- **`AshDispatch.UserPreference.allows_user?/4`** — the preference
  predicate, extracted from `allows?/3` and callable anywhere a user id is
  known: `allows_user?(user_id, event_id, transport, opts)`. This is how an
  admin screen's "342 recipients · 38 have opted out" stays in agreement
  with what the send path will do. A `nil` user id returns `true`.
  `allows?/3` keeps its behaviour and delegates to it.

- **`AshDispatch.UserPreference.allows_receipt?/4`** — the same question
  asked about a receipt's own recipient. This is the gate the transports run.

- **`config :ash_dispatch, preference_gated_audiences`** — which audiences
  have their recipients' preferences consulted. Defaults to `[:user]`,
  exactly the audience set every earlier release gated; every app-defined
  audience (`:customers`, `:watchers`, permission-scoped admin audiences)
  bypassed preferences entirely and still does until opted in:

      config :ash_dispatch, preference_gated_audiences: [:user, :customers]

  Keep admin/team/system audiences out of it — an operator must not be able
  to silence an operational alert by unticking a marketing box.

### Deprecated
- **Channel time `{:window, map}`.** Business-hours windows were never
  implemented; the spec has always delivered immediately. It still does —
  removing it would break consumers that declared one — but the first
  `{:window, …}` channel after boot now logs a deprecation warning. Use
  `{:in, seconds}` or `{:at, %DateTime{}}`. Removal is deliberately
  postponed.

### Docs
- **"Pattern 3: Frequency-Based Preferences" rewritten.** It instructed a
  side effect (`queue_for_digest/3`) inside `user_allows?/4` followed by
  `false` — i.e. a notification silently moved into a table nobody
  delivers from, behind a receipt claiming the user opted out. The
  predicate stays a predicate; digest mode is modelled as "no individual
  delivery" with the digest job owned by the app.

### Planned (names reserved, nothing shipped)
- **Per-recipient digests.** Reserved: channel time `{:digest, window}`,
  `AshDispatch.Resources.DigestEntry.Base`,
  `AshDispatch.Workers.FlushDigests`, and a `user_digest_mode/2` callback
  on the preference behaviour. Two properties are already fixed: the
  digest unit is per recipient (one body per user, not one body for
  everyone), and a digest still produces a `DeliveryReceipt` — a digest is
  a delivery, not a silence. See the User Preferences topic.

## [0.6.3] - 2026-08-17

### Added
- **`DeliveryReceipt.Base` `:list_all` takes an `audiences` list argument**
  alongside the existing single `audience` — apps with scoped audience
  families (e.g. permission-scoped admin audiences) can catch the whole
  family in one filter: `audiences: [:admin, :order_admins, …]`.

  (Written for 0.6.2, but the publish workflow triggers on every main push
  and the version bump sat in the first commit of a two-commit stack — so
  hex 0.6.2 was built mid-stack and never got this argument. Lesson: bump
  the version in the LAST commit of a stack, or push the stack atomically.)

## [0.6.2] - 2026-08-17

### Fixed
- **`ManualTrigger.Base` no longer hardcodes the audience/transport
  universe.** The `:preview` arguments and the `:trigger`-path attributes
  constrained `audience` to `one_of: [:user, :admin]` and `transport` to
  `one_of: [:email, :in_app]` — silently rejecting every app-defined
  audience (`:customers`, `:watchers`, permission-scoped admin audiences)
  and every transport added since. Both are now validated at runtime
  against the consuming app's `config :ash_dispatch, :audiences` and
  `Transport.Registry.receipted_atoms/0`, with the allowed universe listed
  in the error message. Same disease as the receipt-constraint drift fixed
  in 0.6.0; a structural test now pins that no hardcoded list returns.

## [0.6.1] - 2026-08-17

### Fixed
- **A registered transport no longer crashes the whole dispatch.**
  `Dispatcher.build_inline_content/4` had a `case channel.transport`
  with no catch-all, so the `:push` transport added in 0.6.0 raised
  `CaseClauseError` for every event carrying a `:push` channel — taking
  down the sibling channels on the same event with it. The case now has
  a catch-all (a transport without inline content gets `%{}` and still
  delivers), and `:push` has its own branch producing `title`,
  `message` and `action_url`.

  Same drift as the receipt constraint fixed in 0.6.0: the
  `AshDispatch.Transport` behaviour promises "one new file + one
  registry entry", and two places had not got the memo. A structural
  test now pins the catch-all.

## [0.6.0] - 2026-08-17

Adds a Web Push transport and removes the hardcoded transport lists that
made adding one a multi-file hunt.

### Added
- **`:push` transport** (`AshDispatch.Transports.Push`) — Web Push to the
  browser. Same shape as `:sms`: ash_dispatch owns routing and the
  delivery receipt, the consumer supplies a backend module implementing
  the new `AshDispatch.PushBackend` behaviour. Configure with
  `config :ash_dispatch, :push_backend, MyApp.Push`. With no backend
  configured the receipt is marked `:skipped` with
  `error_message: "transport_not_implemented"`, so an app can declare
  `:push` channels before the backend exists.

  VAPID keys, RFC 8291 encryption and the per-endpoint POST stay in the
  consuming app — they are deployment concerns (key material, egress,
  retry budget), not library concerns. `AshDispatch.PushBackend`'s docs
  spell out the contract, including pruning subscriptions on `404`/`410`
  and treating `429`/`5xx` as retryable.

  Declare push channels as `optional: true`: a user who never granted
  notification permission is a soft-skip, not a delivery failure.

- **`AshDispatch.Transport.Registry.receipted_atoms/0`** — the transport
  atoms that can appear on a `DeliveryReceipt` (registry minus the
  lightweight `:broadcast`/`:oban`).

### Fixed
- **The receipt `transport` constraint no longer drifts.** It was
  hardcoded in two places that had already gone out of sync:
  `AshDispatch.Setup` allowed `[:email, :in_app, :discord, :sms,
  :webhook]` while `DeliveryReceipt.Base` allowed those plus `:slack`.
  A `:slack` channel therefore produced a receipt the `Setup`-generated
  resource rejected. Both now derive from `receipted_atoms/0`, so
  registering a transport is once again "one new file + one registry
  entry" as `AshDispatch.Transport`'s docs promise.

### Compatibility
No migration required. The receipt constraint only widens, and consumers
that never declared a `:push` channel are unaffected.

## [0.5.6] - 2026-08-12

Security-focused release absorbing a consumer-proven patch set (policies and
retry semantics that one production app had carried as local vendor patches),
plus inline-image email support.

### Security
- **`Notification.Base` now ships `Ash.Policy.Authorizer` with per-user
  policies**: read and update only your own notifications,
  `mark_all_as_read`'s `user_id` argument must match the actor, and
  create/destroy are system-only. Without an authorizer, `authorize?: true`
  was a no-op — any signed-in user could read every other user's
  notification feed (proven in one production deployment) and mark other
  users' feeds as read. The in-app transport now creates notifications with
  `authorize?: false` at both call sites (initial delivery and retry).
- **`ManualTrigger.Base` is now fail-closed**: it declares the authorizer
  with no base policies, so everything is forbidden until the consuming app
  opens access with its own `policies` block (typically a `bypass` on its
  admin check). Previously any signed-in user could preview arbitrary
  records as email bodies and trigger real outbound email. Note for
  integrators: the base deliberately does NOT declare a
  `forbid_if always()` policy — base policies compile before the
  consumer's, and a later consumer `bypass` cannot re-open an earlier
  forbid.
- **`DeliveryReceipt.Base` write policies**: the blanket
  `bypass … authorize_if always()` on create/update/destroy let any
  authenticated actor mutate receipts — including `:retry`, which re-sends
  real email. External writes are now gated on the same configured
  permission as reads (`:manage_delivery_receipts` via the configured
  `permission_checker`). All library-internal writes already run with
  `authorize?: false` and are unaffected.
- **`EmailEvent` reads forbade everyone, super admins included** — its two
  non-bypass policies were AND-ed. The super-admin policy is now a `bypass`.

### Added
- **Inline (CID) email images**: `attachments/2` attachment maps accept
  optional `type: :inline | :attachment` and `cid: String.t()`. Inline
  attachments flow through the Oban job args and reach the Swoosh backend as
  `type: :inline` with `cid` defaulting to the filename — referenced from
  HTML as `<img src="cid:logo.png">`, they render without the recipient
  approving remote images. Plain attachments are byte-for-byte unaffected,
  and in-flight jobs enqueued by older versions decode unchanged.
- **App-wide default email attachments**: `config :ash_dispatch,
  default_email_attachments: {MyApp.EmailAssets, :defaults, []}` (MFA or
  zero-arity fun returning attachment maps) is merged ahead of each event's
  own `attachments/2` on every outgoing email. Built for the inline-logo
  case: one config line embeds a `type: :inline` logo referenced from a
  shared layout as `<img src="cid:logo.png">`. Resolution failures log and
  degrade to no attachments — branding must never block delivery.
- **`should_send?/2` is now actually invoked by the send path** (per
  channel, on both the direct-dispatch and notifier paths, including the
  deduplication path). The callback was declared on the behaviour — and
  implemented by consumer events as a last-moment guard — but never called,
  so those guards silently never ran. A guard that raises logs a warning and
  sends (dispatch is never aborted by a guard).

### Fixed
- **Retry race that silently dropped mail**: `RetryFailedDeliveries` now
  moves the receipt to `:scheduled` BEFORE enqueueing the worker, and puts
  it back to `:failed` (or `:failed_permanent` once retries are spent) if
  the enqueue fails; `mark_sending` additionally accepts `:failed` as a
  source state, which also makes Oban's own backoff retries effective.
  Previously the worker regularly ran while the receipt was still `:failed`,
  treated it as a duplicate job, returned `:ok`, and the receipt stranded on
  `:scheduled` where no retry path ever saw it again — in one production
  deployment this silently dropped 17 emails over eight months.
- `mark_failed` no longer increments `retry_count` (a failure is not a
  retry). With both `mark_failed` and `:retry` incrementing, every
  failed-and-retried cycle burned the retry budget twice as fast as
  `:max_retries` promised.
- Provider webhook events no longer overwrite each other:
  `record_webhook_event` merges into the existing `provider_response`, and
  the Resend handler namespaces each payload under its event type
  (`"email.delivered" => %{…}`), so the full delivery timeline — and the
  original send response with the provider id — survives.
- The email preference check now uses the category the event module actually
  declares (`category` in the dispatch DSL), falling back to the old
  event-id string munging. Munged ids only matched preference fields by
  coincidence, silently disabling opt-out toggles for events whose id
  didn't mirror a preference column.
- Retried emails no longer lose their attachments: retry/send-now jobs are
  built with `SendEmail.new_for_receipt/1`, which carries the original job's
  attachment args forward (attachments are resolved once, at first enqueue,
  and exist only in job args — a bare `%{receipt_id: _}` retry job resent
  the mail without them, breaking inline images).

### Fixed (0.2.x parity regressions)
- Restored the `authorize?: false` counter-scoping guard in
  `ResourceIntrospection.resolve_user_id_path_for_scoping/2` (present in
  0.2.x, lost in the notifier-era refactor): a counter with
  `authorize?: false` and no explicit `scope`/`user_id_path` is system-wide
  again, instead of silently auto-deriving a user scope and reading 0 for
  admin badges. Both callers already passed the option; it was ignored.
- `CounterLoader` audience matching now fails CLOSED for audiences
  configured as MFA/function resolvers: they cannot be evaluated against a
  single user, and the old fallthrough parsed them as an empty filter —
  "matches everyone" — broadcasting admin counters to every signed-in user.
  Counter audiences should use the declarative list form.
- All library-internal receipt/notification state writes now pass
  `authorize?: false` explicitly (receipt_status, every transport, the
  dispatcher's unknown-transport skip). They previously relied on
  `DeliveryReceipt.Base`'s blanket write bypass, which this release removed
  — without this, the tightened policies broke email/in-app delivery
  end-to-end for any consumer.

### Upgrade notes
- **`#{@var}` template interpolation is no longer converted.** The 0.2.x
  preprocessor rewrote `#{@var}` in mail templates to EEx; the current
  resolver deliberately skips `#{` (it can be legitimate Elixir
  interpolation inside a HEEx attribute expression). Body-position
  `#{@var}` now renders as literal text — migrate templates to `{@var}`
  (also auto-escaped since 0.4.6).
- Apps using `ManualTrigger.Base` MUST add a `policies` block to their
  trigger resource or the admin UI built on it will see empty lists:

      policies do
        bypass always() do
          authorize_if MyApp.PolicyHelpers.AdminCheck
        end
      end

- Apps exposing `DeliveryReceipt` actions (`:retry`, `:send_now`, reads)
  to their frontend need a `permission_checker` configured whose
  `:manage_delivery_receipts` permission matches their admin model.
- In-app retries now consume retry budget (`retry_count` increments on the
  synchronous in-app retry path as well).

## [0.5.5] - 2026-08-12

### Fixed
- `SendWebhook` pattern-matched on the `%Req.Response{}` struct although
  `req` is an optional dependency — any app without req failed to COMPILE
  the library in prod builds (dev builds often hid it via a transitive
  dev-only req). Now matches plain maps; the runtime `Req.post/2` call is
  unaffected and still requires req only when the webhook transport is
  actually used.

### Fixed
- The i18n catalog generator (`mix ash_dispatch.gen`) registered msgids
  under a hardcoded `"notifications"` domain while the Dispatcher looks
  them up via the configurable `:gettext_domain` — for any app setting
  that config, every dispatch translation silently missed. The generator
  now uses `Config.gettext_domain/0`.

## [0.5.4] - 2026-08-11

0.5.2 was never published — its changes ship here. (An earlier changelog
revision folded them into 0.5.3; in fact 0.5.3 had already been published
2026-07-14 with the attachment work alone, so they ship as 0.5.4.)

### Added
- **Resend webhook signature verification**:
  `AshDispatch.WebhookHandlers.Resend.verify/3` — Svix HMAC over
  `svix-id.svix-timestamp.raw_body` with constant-time comparison,
  multi-signature support (secret rotation) and a replay window. Ported
  from a client app, where it was the only verified endpoint in the
  fleet; siteflow/magasin expose unauthenticated receipt mutation today.
- **Sensitive-content scrubbing**:
  `AshDispatch.Workers.ScrubSensitiveContent` (cron) blanks `body_text`/
  `body_html` of receipts whose event declares
  `metadata: [sensitive_content: true]` once they are older than
  `config :ash_dispatch, :scrub_after_hours` (default 24). Receipts in
  `:failed` are left for the retry path first. Replaces app-level scrub
  workers .
- **`Dispatcher.dispatch_safely/3`** — rescue-and-log wrapper for
  fire-and-forget dispatch from code paths that must never be felled by a
  notification failure. mosis carries two hand-rolled copies of this
  (`Mosis.AshDispatch.dispatch_safely`, `AshDispatchAdapters.BestEffort`);
  they can be retired on upgrade.
- `BACKLOG.md`: design-level findings from the 2026-08-10 cross-app
  integration audit (retry semantics, ManualTrigger trigger no-op arguments,
  dead surface).
- CI: `ci.yml` runs format check + tests on every PR and push to main;
  `publish.yml` gained a version guard so re-pushing an already-published
  version no longer fails the pipeline.

### Changed
- Widened optional `hackney` constraint to `~> 1.9 or ~> 4.0` so the library
  coexists with dependencies that require hackney 4.x (e.g. stripity_stripe
  3.x). hackney is only used when Swoosh is configured with a hackney-based
  API client; projects using other adapters are unaffected.
- Downgraded the per-dispatch "No :user_module configured" log line from
  warning to debug. An app without a user resource is a valid configuration
  (custom recipient resolvers handle non-user recipients); the two
  recipient-resolution failure diagnostics keep their warning level.
- `SendEmail` with no `:email_backend` configured now marks the receipt
  `:skipped` ("no email_backend configured") with a warning, instead of
  logging `[MOCK]` and marking it `:sent` — a receipt claiming a delivery
  that never happened.
- `ValidateCanRetry` (the receipt `:retry` action) now reads
  `config :ash_dispatch, :max_retries` (default 5) instead of a hardcoded 5
  that silently overrode the same knob `RetryFailedDeliveries` honors.

### Deprecated
- `AshDispatch.Resources.ManualTrigger` (the legacy non-Base variant): its
  `:trigger` action fails `Dispatcher.dispatch/3`'s map guard with a
  `FunctionClauseError`. Use `AshDispatch.Resources.ManualTrigger.Base`.
  Removal planned for 0.6.

## [0.5.3] - 2026-07-14

### Added
- End-to-end email attachment support: events can implement
  `attachments/2`; attachments flow through the Oban job (base64) into the
  Swoosh backend (#5).

## [0.5.1] - 2026-06-29

Documentation-only release. Rebrands the project for its public launch.

### Changed

- **README rebranded for the `0.5` public launch.** Hex.pm + HexDocs
  badges, a prominent "experimental, API may change before 1.0" caveat,
  install instructions bumped to `~> 0.5`, and reworked Project Status /
  Contributing sections (dropping the pre-launch "being extracted / will
  be published" framing).
- Generic `MyApp.*` module names in the manual-dispatch tutorial
  (previously referenced an internal application name), and issue links
  point at the public repo.
- Corrected the dispatch-flow legend in *What is AshDispatch?* — email
  and webhook delivery run on real Oban workers; the mock is only the
  default email backend.

## [0.5.0] - 2026-06-29

First public release on hex.pm since `0.1.4` — brings the public package
up to current. Headline additions are two new transports and a formal
`Transport` behaviour.

### Added

- **`:oban` transport.** Dispatch an event straight to an Oban worker,
  eliminating the manual dispatch+enqueue dance. Wired via
  `use AshDispatch.Event, transports: [oban: [...]]`.
  - **Compile-time validation**: an `:oban` channel now requires
    `:oban_worker` metadata (previously a soft runtime warning + a
    `:skipped` receipt that left operators staring at an empty queue).
  - **Dispatch-layer enable-gate** via a pluggable
    `config :ash_dispatch, :gate_check_module`. A disabled gate skips
    the enqueue entirely (emitting `[:ash_dispatch, :oban, :gated_disabled]`
    telemetry) instead of burning queue capacity on a no-op worker.
    No gate configured → always enabled; a raising gate → defaults to
    enabled (over-fire is safer than a silent drop) and logs a warning.

- **`:custom_topic` transport.** A lightweight per-record PubSub
  broadcaster (`AshDispatch.Event.CustomTopic`) for fire-and-forget
  broadcasts that need no recipients, content, or `DeliveryReceipt`s.
  Topic accepts a string or a `{Module, :function}` MFA for per-record
  routing. Generates overridable `topic/0,1`, `event_name/0`,
  `safe_broadcast/1,2` helpers wrapping `Phoenix.PubSub.broadcast/3`
  with rescue + log + `[:ash_dispatch, :custom_topic, :broadcast_failure]`
  telemetry. The heavyweight Spark DSL path is unchanged when no
  `:transports` option is passed.

- **`AshDispatch.Transport` behaviour + Registry.** Dispatcher routing
  is now derived from a registry of transports rather than hardcoded,
  giving new transports a single integration point.

- **Module-typed `dispatch/3` overload** on `AshDispatch.Dispatcher`,
  resolving `event_id` via the `EventRegistry`.

- **`AshDispatch.Naming.wire_event_name/1`**, consolidating the
  dotted-split-and-take-last logic previously private to the Broadcast
  transport so other transports can reuse it.

### Fixed

- **`RecipientResolver` never aborts the parent operation.** Dispatch is
  a side-channel: recipient resolution now wraps its body in
  `try/rescue`, so a bad `user_resource` config or a raise from an
  auto-loaded calculation (e.g. an unstarted Cloak vault) degrades to
  `[]` recipients + a structured warning instead of bubbling an
  exception up and aborting the caller's transaction.

- **Cleared all Elixir 1.20 compiler warnings** (unused requires,
  unreachable `defp` clauses, bitstring `size(...)` pins, always-truthy
  guards). Behavior-preserving.

## [0.4.8] - 2026-05-14

### Fixed

- **Process-local Gettext locale leak after dispatch.** `Gettext.put_locale/2`
  is process-local. `apply_recipient_locale/3` mutates the running
  process's locale so per-recipient renders pick up the right language.
  Until now, after `build_receipt_content/4` returned, the process was
  left with **the last recipient's locale** — which meant a worker that
  dispatched event A to a `locale="en"` user and then ran any `t()`
  call for its own purposes (audit logging, custom emails, follow-up
  derivations) would see the leaked "en" locale instead of the locale
  the worker started with.

  Fix: `build_receipt_content/4` now captures `current_locale/0` before
  applying the recipient locale and restores it in an `after` block. Each
  receipt build is fully isolated; the caller's process locale is
  unchanged on return.

  Caught via crash-hunt regression: `t()` between two dispatches now
  renders correctly against the worker's surrounding locale.

## [0.4.7] - 2026-05-14

This release unlocks **DSL-only locale-aware events**. Combined with
0.4.6's HEEx auto-escape, an entire event can live in
`dispatch do … end` blocks with just `prepare_template_assigns/2`
left in the event module for derived assigns.

### Added

- **Configurable Gettext domain** for DSL content lookups
  (`AshDispatch.Config.gettext_domain/0`, default `"notifications"`).
  Apps with existing `default.po` setups can do
  `config :ash_dispatch, :gettext_domain, "default"` to share one
  translation bundle across the codebase.

- **Top-level `template_assigns` interpolation in `VariableInterpolator`.**
  When a variable doesn't match a field on the main resource, the
  interpolator now falls back to top-level keys in `data`. Lets
  `prepare_template_assigns/2`-returned values be addressed directly as
  `{{my_computed_var}}` instead of awkwardly stuffing them onto the
  resource struct.

### Fixed

- **`translate_content/2` no longer overwrites recipient locale.**
  Previously, when `context.locale` was nil the function unconditionally
  reset Gettext to `"en"` — silently undoing the per-recipient locale
  that `apply_recipient_locale/3` had just set. Now only overrides on
  explicit non-empty locale; trusts the process-level locale otherwise.

- **`action_label` now goes through `interpolate/2`** for `:in_app`
  channels — parity with `title`/`message`/`subject` so DSL-declared
  labels participate in both `{{var}}` substitution AND the gettext
  translation pipeline. Previously rendered raw.

## [0.4.6] - 2026-05-13

### Security

- **Auto-escape `{@var}` expansions in HTML email templates.**
  `TemplateResolver.render_template_content/4` previously rewrote
  HEEx-style `{@var}` markers to plain EEx `<%= @var %>` and evaluated
  the result via `EEx.eval_string/2`, which does NOT HTML-escape
  interpolated values. Any user-controlled string flowing through
  `prepare_template_assigns/2` (lead name, contract recipient, customer
  comment, etc.) landed raw in the rendered email — a real markup
  injection vector.

  The preprocessor now wraps every auto-converted `{@var}` expansion in
  `AshDispatch.SafeRender.escape/1` for `format: :html` so escape is the
  default, matching Phoenix HEEx semantics. Text formats are unaffected
  — `email.text.eex` and similar still emit `<%= @var %>` plain
  (text/plain has no HTML semantics).

  **Migration:** if your templates intentionally embed safe pre-rendered
  HTML, mark those expressions explicitly:

      <p>{raw(@trusted_block)}</p>
      <!-- or, fully qualified -->
      <p>{AshDispatch.SafeRender.raw(@trusted_block)}</p>

  `{:safe, iodata}` tuples (Phoenix.HTML's standard "already escaped"
  marker) also pass through `escape/1` unchanged, so existing
  Phoenix.HTML interop keeps working.

### Added

- `AshDispatch.SafeRender` module (`escape/1` + `raw/1`).

## [0.4.5] - 2026-05-13

### Added
- **Per-recipient locale resolution.** When a channel resolves to a
  multi-recipient audience (e.g. seller + admin), each recipient's
  rendered notification content now follows their own `recipient.locale`
  field. The resolution priority is:

      1. channel.locale       (static override)
      2. channel.locale_from  (channel-level dynamic on primary record)
      3. recipient.locale     (NEW — auto-detected when recipient struct has it)
      4. event/resource locale_from + auto-detected visitor_locale/locale
      5. context.locale + Config.default_locale()

  This makes multilingual sends — e.g. a customer-facing email to a
  Swedish lead, plus an internal email to an English admin — render in
  each recipient's preferred language from one event dispatch, with no
  per-recipient code in the calling worker. The recipient struct just
  needs a `:locale` field (typically a `User` record); audiences that
  expose user records via `RecipientResolver.to_recipient/1` get this
  for free.

### Changed
- `Dispatcher.build_receipt_content/4` now threads `recipient` into
  `build_module_content`, `build_inline_content`, and
  `render_inline_email_templates`. Subject + html/text bodies are now
  rendered per recipient with the correct locale, instead of once per
  channel. Pre-render side: the resolved locale is also stamped on the
  receipt for analytics/traceability.
- `Gettext.put_locale/2` is now invoked automatically inside
  `build_receipt_content` (via the new `apply_recipient_locale/3`
  helper) when `:gettext_backend` is configured. Consumer code that
  was previously calling `Gettext.put_locale` itself before
  `Dispatcher.dispatch/2` to influence content can drop that — the
  dispatcher handles it per-recipient.

## [0.4.4] - 2026-05-12

### Added
- **Pluggable SMS transport backend.** `AshDispatch.Transports.SMS` now
  delegates to a consumer-configured module implementing the new
  `AshDispatch.SMSBackend` behaviour. Configure with
  `config :ash_dispatch, :sms_backend, MyApp.SMS`. When no backend is
  configured the receipt is still marked `:skipped` with
  `error_message: "transport_not_implemented"`, preserving the prior
  stub behavior for consumers that haven't wired SMS yet.
- **`optional: true` channel option.** When a channel is marked optional
  and recipient identifier extraction fails (e.g. SMS channel for a
  user with no `phone_number`), the dispatcher logs and skips that
  channel rather than crashing the whole dispatch. Non-optional channels
  still re-raise as before.

## [0.4.3] - 2026-05-12

### Fixed
- **Catch the remaining 5 `channel.on`/`socket.on`/`channel.join().receive`
  callsites the v0.4.2 sweep missed.** 0.4.2 only widened 3 of the 8
  typed-payload callbacks in the SDK generator; consumers running TS
  strict mode still saw `TS2345` on the rest:
  - `hooks/use-channel.ts` — `channel.join().receive('ok', (response:
    ChannelJoinResponse) → unknown)` and `channel.on('counter_updated',
    (payload: CounterUpdatePayload) → unknown)`
  - `hooks/use-notifications.ts` (standalone mode) — `channel.on('initial_state',
    (payload: { counters?: ... }) → unknown)`,
    `channel.on('new_notification', (notification: Notification) → unknown)`,
    and `socket.on('new_notification', ...)`
  All 8 sites now use the same `(rawX: unknown) => { const x = rawX as
  T; ... }` pattern.

## [0.4.2] - 2026-05-12

### Fixed
- **TypeScript SDK generator emits strict-mode-clean channel handlers.**
  Previously, `channel.on('initial_state', (payload: {...}) => {...})` failed
  to type-check in consumers running `strict: true` (saleflow) because
  phoenix-js types the callback parameter as `(payload: unknown)` and TS
  function-parameter contravariance rejects narrower handler types.
  Generator now widens all `channel.on`/`socket.on` callbacks to
  `(rawPayload: unknown)` and narrows via an inline `as`-cast. Affects
  `socket-provider.tsx` (3 sites: `initial_state`, `counter_updated`,
  `entity_change`) and `hooks/use-notifications.ts` (2 sites:
  `channel.on('counter_updated')` + `socket.on('counter_updated')`).
- **`notification-bell.tsx` no longer imports unused `useState`.** Was
  emitting a `TS6133` violation under `noUnusedLocals`.

## [0.4.1] - 2026-05-12

### Added
- **`:table` option on `Notification.Base` and `DeliveryReceipt.Base`**. Lets
  consumer apps override the Postgres table name when their app already owns
  `notifications` / `delivery_receipts` for a legacy notification system and
  ash_dispatch needs to coexist rather than collide. Defaults preserve current
  behavior (`"notifications"` / `"delivery_receipts"`), so existing consumers
  upgrade transparently.

  Example:

      defmodule MyApp.Dispatch.Notification do
        use AshDispatch.Resources.Notification.Base,
          repo: MyApp.Repo,
          domain: MyApp.Dispatch,
          table: "dispatch_notifications"
      end

## [0.4.0] - 2026-05-12

### Changed (substrate retrofit — tx-semantics)
- **DispatchEvent and BroadcastCounterUpdate now route through `Ash.Notifier`**, not `Ash.Changeset.after_action/2`. Pre-retrofit, these changes fired synchronously inside the action's transaction BEFORE commit/rollback, allowing phantom dispatches and counter broadcasts when a wrapping `Ash.transaction/2` rolled back. Post-retrofit, work runs in `Ash.Notifier`'s commit-deferred firing path and is dropped on rollback (see Ash's `transaction/2` defer-and-fire-or-drop semantics). New shape: single `AshDispatch.Notifier` module + `AshDispatch.Notifier.Info` Spark Info reader; per-action config persisted into `dsl_state` by the `InjectDispatchChanges` and `InjectCounterBroadcasts` transformers and read at runtime by the notifier. Mirrors `Ash.Notifier.PubSub`'s canonical pattern.
- **Behaviour fix: receipt creation is now post-commit only**. `DeliveryReceipt` rows previously could land for events whose triggering action subsequently rolled back. Post-retrofit they only land for actually-committed actions. Orphan receipts on rollback were a bug, not a feature.
- **Removed `lib/changes/dispatch_event.ex` and `lib/changes/broadcast_counter_update.ex`** (845 LOC). Their orchestration logic moved to `lib/notifier/dispatch_handler.ex` and `lib/notifier/counter_handler.ex` respectively, exposed as public entry points the notifier calls.
- **Canary regression net** added at `test/notifier_tx_semantics_test.exs` — two tests (`refute_receive` after force-rollback via raise, `refute_receive` inside the txn before commit) that lock in the contract going forward.
- **DeliveryReceipt**: allow `:failed → :sent` transition for retry-after-failure paths. Previously the receipt was stuck in `:failed` even after a successful re-send.
- **Broadcast transport**: drop per-event log warning when `pubsub_module: nil` (documented passive-shell posture); consumers wanting a presence check should read `Config.pubsub_module()` once at app boot.

### Added
- Initial release of AshDispatch
- Event-driven notification system for Ash Framework
- Multiple transport types:
  - Email transport with Swoosh backend
  - In-app notifications
  - Discord webhooks
  - Slack webhooks
  - SMS transport (stub)
  - Generic webhook transport
- Delivery receipt tracking with state machine
- Automatic retry system for failed deliveries
- User preference checking for email notifications
- Recipient resolution behaviours
- Event DSL with template interpolation
- Comprehensive documentation and guides
- Testing utilities and helpers

### Fixed
- **Hybrid mode callback fallback**: Inline DSL now properly falls back to event module callbacks when fields are not provided. Previously, nil values from inline DSL would overwrite module callback results. Now, only non-nil inline DSL values are included in the content map, preserving module callbacks for dynamic content like `notification_message/2`, `subject/2`, and `action_url/2`

## [0.1.0] - 2025-01-17

### Added
- First alpha release
- Core dispatcher and event system
- Basic transport implementations
- Oban worker integration
- DeliveryReceipt and Notification resources
- Documentation structure with ex_doc

[Unreleased]: https://github.com/Vulcora/ash_dispatch/compare/v0.4.3...HEAD
[0.4.3]: https://github.com/Vulcora/ash_dispatch/compare/v0.4.2...v0.4.3
[0.4.2]: https://github.com/Vulcora/ash_dispatch/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/Vulcora/ash_dispatch/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/Vulcora/ash_dispatch/compare/v0.1.0...v0.4.0
[0.1.0]: https://github.com/Vulcora/ash_dispatch/releases/tag/v0.1.0
