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
- The per-tenant tests (`test/tenancy/`, tagged `:postgres`) are the exception
  to "no database": `strategy :context` IS a Postgres schema prefix, so they
  create two real schemas and generate each resource's table from its own
  attributes and identities (`AshDispatch.Test.Schema`). Without
  `ASH_DISPATCH_TEST_DATABASE_URL` they are excluded, and what is left still
  covers the compatibility half — that a resource without multitenancy is never
  handed a tenant.

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
on 0.8.6.

## The tenancy suite

`test/tenancy/` is the per-tenant half, and every file in it is tagged
`:postgres` except the ones that need no database (`cron_fanout_test.exs`,
`opted_into_nothing_test.exs`, `lower_severity_test.exs`,
`tenants_cost_test.exs`, and the compatibility half of
`compatibility_test.exs`). Most of it came out of the independent review of
0.9.4-rc.0, so each file names the property it holds rather than the function
it calls:

- `struct_tenant_test.exs` — a tenant whose schema is not its `:id`
- `transient_missing_table_test.exs` — a tenant mid-migration is retried
- `missed_reads_test.exs` — the reads of the HOST's resources
- `webhook_trust_test.exs` — what the endpoint may be told, and what it answers
- `minimal_args_test.exs` — `job_args: :minimal`'s empty letter and its From
- `opted_into_nothing_test.exs` — the two ways rc.0 reached a host with no
  tenancy at all
- `cron_fanout_test.exs` — one pass per tenant, and an honest result
- `tenants_cost_test.exs` — what one `Tenants.check/1` costs the host
- `odd_tenants_test.exs` — a tenant name cannot become SQL
- `compatibility_test.exs` — the spy, and `AshDispatch.Test.TenantAudit`'s AST
  walk over `lib/`

`AshDispatch.Test.TenantAudit` is the structural half: it fails the build if a
tenant reaches Ash or the repo anywhere in `lib/` without going through
`AshDispatch.Tenancy`. Two text searches stood there until 0.9.4-rc.1 and
seven ordinary spellings got past them.
