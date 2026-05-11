# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/Vulcora/ash_dispatch/compare/v0.4.1...HEAD
[0.4.1]: https://github.com/Vulcora/ash_dispatch/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/Vulcora/ash_dispatch/compare/v0.1.0...v0.4.0
[0.1.0]: https://github.com/Vulcora/ash_dispatch/releases/tag/v0.1.0
