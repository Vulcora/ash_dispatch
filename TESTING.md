# Testing AshDispatch

## Running the suite

```bash
mix deps.get
mix test
```

The suite is self-contained: it needs no database and no consuming app.

- Resources under test use `Ash.DataLayer.Ets` (`test/support/`), including
  `AshDispatch.Test.TransportReceipt`, an ETS stand-in for the
  `DeliveryReceipt.Base` resource that the transports and send workers can
  read and update.
- The real `DeliveryReceipt.Base` resource is compiled through
  `use AshDispatch.Setup` (`test/support/test_setup.ex`) against a repo that
  is never started, so its actions are built as changesets and inspected,
  never run.
- `mix ash_dispatch.install` is exercised with Igniter's test project
  (`test/mix/tasks/`).

## What CI runs

`.github/workflows/ci.yml`:

- **test** — `mix format --check-formatted` and `mix test`.
- **compile-without-optional-deps** — builds ash_dispatch as the only
  dependency of a bare app, on the oldest supported Elixir, and fails on any
  warning: library code must not start requiring an optional dependency
  (swoosh, req, ash_typescript, igniter, …).
- **installer** — runs `mix ash_dispatch.install` in a fresh Ash app
  (`.github/fixtures/installer_app`) and requires the result to compile
  without warnings and to generate migrations.

## Testing your app's notifications

That belongs in the consuming app, against its own database and Oban. The
library ships helpers for it — see the *Previews and testing* guide
(`AshDispatch.Test.assert_all_render/1`, `AshDispatch.Preview`) once you are
on 0.9.
