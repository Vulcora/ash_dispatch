# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
