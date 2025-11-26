# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/Vulcora/ash_dispatch/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Vulcora/ash_dispatch/releases/tag/v0.1.0
