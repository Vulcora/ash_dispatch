# Testing AshDispatch

## Overview

AshDispatch is a library that provides event dispatching capabilities for Ash resources. The test suite is split between:

1. **Library tests** (in `ash_dispatch/test/`) - Pure unit tests for calculations
2. **Integration tests** (in consuming app, e.g., `magasin/test/ash_dispatch/`) - Full integration tests

## Running Library Tests

```bash
cd ash_dispatch
mix test
```

**Output:**
```
2 tests, 0 failures ✅
```

The library tests include:
- `test/calculations/load_user_test.exs` - Tests for the LoadUser calculation
- Future unit tests for other calculations and utilities

These tests run **standalone** without requiring a consuming application.

## Running Integration Tests

Integration tests run in the context of a consuming application (e.g., `magasin`):

```bash
cd ../magasin  # or your consuming app
mix test test/ash_dispatch/
```

**Output:**
```
478 tests, 0 failures ✅
```

Integration tests include:
- Email backend tests (`swoosh_test.exs`)
- Worker tests (`send_email_test.exs`, `retry_failed_deliveries_test.exs`, `send_webhook_test.exs`)
- Full end-to-end integration tests (`integration_test.exs`)
- Resource-specific tests with real database and Oban

## Why This Structure?

AshDispatch uses runtime configuration to avoid compile-time dependencies on consuming applications. This means:

- The library itself has minimal test fixtures
- Full integration testing requires a real application context (magasin)
- This is a common pattern for Ash extensions and libraries

## Cross-Project User Association

The library uses **calculations instead of belongs_to** to avoid compile-time warnings:

### Old Approach (caused warnings):
```elixir
# In DeliveryReceipt
belongs_to :user, Magasin.Accounts.User  # ❌ Compile warning!
```

### New Approach (clean):
```elixir
# In DeliveryReceipt
calculate :user, :struct, {AshDispatch.Calculations.LoadUser, []}  # ✅ No warning
```

This is the **recommended Elixir/Ash pattern** for cross-project references:
- No compile-time dependency on consuming app's modules
- Runtime configuration via `config :ash_dispatch, user_resource: MyApp.User`
- Batch loading for efficiency
- Works exactly like a relationship when you use `Ash.Query.load(:user)`

## Configuration Required

```elixir
# config/config.exs
config :ash_dispatch,
  user_resource: MyApp.Accounts.User,
  user_domain: MyApp.Accounts
```

## Usage

Loading users works the same as belongs_to:

```elixir
# Load user relationship
receipt
|> Ash.Query.load(:user)
|> Ash.read!()

# Access user
receipt.user.email
```

The calculation automatically batch-loads users for efficiency.
