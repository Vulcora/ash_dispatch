# Tenancy

AshDispatch has known what a tenant is since 0.8.8 and stored one since 0.9.0,
but only ever as a value it passed along: every read and write it made, it made
without one. For a host whose receipts and notifications live in the public
schema that is fine, and it stays fine — **a host that does nothing sees
nothing of this page.**

For a host with `multitenancy strategy :context` and one Postgres schema per
tenant it was not fine: a receipt written during a tenant's action landed in
`public`, the send worker read it back from `public` by luck rather than by
design, and `ScrubSensitiveContent` — a raw `UPDATE` against a table name with
no prefix — never reached a tenant schema at all, so one-time tokens and reset
links stayed in it for good.

Since 0.9.4 the tenant is carried through the whole flow, for the hosts that
ask for it.

## The two things `:tenant` can mean

They are different, they are both useful, and which one you get is decided by
the **resource**, not by the option:

| | `tenant` column | `multitenancy: :context` |
|---|---|---|
| Where rows live | one table for every tenant | one schema per tenant |
| What it is for | "which tenant was this for?" — reports, filters | isolation, and data residency |
| Migration | one nullable column | a schema and tables per tenant |
| Provider webhooks | work unchanged | need the tenant (see below) |
| Cron | unchanged | one pass per tenant |

A host can have both: a per-tenant receipt may also carry the column, and a
report that spans tenants then has something to group by without reading twenty
schemas.

`AshDispatch.Tenancy` is the one place that decides whether a tenant is
mentioned to Ash at all. It asks the resource, never the presence of a tenant —
Ash *tolerates* a tenant on a resource without multitenancy, and a library
should not rely on being ignored.

## Per-tenant receipts: what to add

### 1. Switch the resources over

```elixir
defmodule MyApp.Deliveries.DeliveryReceipt do
  use AshDispatch.Resources.DeliveryReceipt.Base,
    repo: MyApp.Repo,
    domain: MyApp.Deliveries,
    notification_resource: MyApp.Notifications.Notification,
    multitenancy: :context
end

defmodule MyApp.Notifications.Notification do
  use AshDispatch.Resources.Notification.Base,
    repo: MyApp.Repo,
    domain: MyApp.Notifications,
    multitenancy: :context
end

defmodule MyApp.Notifications.Preference do
  use AshDispatch.Resources.Preference.Base,
    repo: MyApp.Repo,
    domain: MyApp.Notifications,
    multitenancy: :context
end
```

That declares

```elixir
multitenancy do
  strategy :context
  global? false
end
```

`global? false` is deliberate: a dispatch without a tenant then **fails
loudly** instead of writing to `public`. Two homes for receipts is how a
receipt stops being an audit trail. A host with both tenant-scoped and
system-wide events wants `multitenancy: {:context, global?: true}` — or, more
likely, public receipts and `tenant_column: true`.

### 2. Generate and run the migrations

```bash
mix ash.codegen move_dispatch_to_tenants
mix ash.migrate
```

Moving existing rows out of `public` is yours to write: the library has no way
to know which tenant a row from before belonged to unless the receipt carried
the `tenant` column. If it did, the move is one `INSERT … SELECT` per tenant.

### 3. Say which tenants exist

```elixir
config :ash_dispatch, tenants: MyApp.Tenants
```

```elixir
defmodule MyApp.Tenants do
  @behaviour AshDispatch.Tenants

  @impl true
  def all do
    MyApp.Accounts.Organisation
    |> Ash.Query.filter(active == true)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.schema)
  end
end
```

This is needed for two things, and it is not optional for either:

- the two scheduled workers run **once per tenant**, and they cannot find the
  tenants otherwise. Without this, nothing is retried and nothing is scrubbed —
  and the workers say so once per VM rather than reporting success every five
  minutes;
- a tenant that arrives **from outside** — a provider's webhook tag, an Oban
  job's args — is held against `c:AshDispatch.Tenants.known?/1` before it
  reaches a query. A tenant is a Postgres schema name.

### 4. Pass the tenant where you dispatch

An action-triggered event takes the action's tenant, so nothing changes there.
A manual dispatch says it:

```elixir
AshDispatch.Dispatcher.dispatch("bookings.confirmed", %{booking: booking}, %{},
  tenant: tenant
)
```

### 5. Pass it where you read

The functions a host calls take a `:tenant`, and it is **required** when the
resource is per tenant:

```elixir
NotificationLoader.load_recent(user.id, tenant: tenant)
NotificationLoader.unread_count(actor: user, tenant: tenant)
NotificationLoader.mark_all_as_read(user.id, actor: user, tenant: tenant)
CounterLoader.load_counters_for_user(user.id, tenant: tenant)
AshDispatch.Preview.render("bookings.confirmed", {:record, id}, tenant: tenant)
AshDispatch.UserPreference.Resource.put(%{tenant: tenant, user_id: user.id, …}, false)
```

`AshDispatch.Phoenix.LiveView`'s `:tenant` option already names where the
tenant is in the assigns; it now means the schema for a per-tenant
notification resource, and the column for one in the public schema.

### 6. Decide how provider webhooks find their tenant

A provider webhook arrives with a message id and nothing else. Three answers,
in the order to prefer them:

1. **A per-tenant endpoint.** Your router already knows how to put a tenant in
   a path:

   ```elixir
   post "/webhooks/resend/:tenant", WebhookController, :resend
   ```

   ```elixir
   AshDispatch.WebhookHandlers.Resend.process_webhook(params, tenant: tenant)
   ```

   Nothing depends on what the provider echoes back, so it works for every
   provider.
2. **A provider tag**: `config :ash_dispatch, webhook_tenant_tag: true` sends an
   `X-AshDispatch-Tenant` header with every message and reads it back out of
   the payload. Only switch this on behind
   `AshDispatch.WebhookHandlers.Resend.verify/3`: without a verified signature
   the tag is a value a stranger chose. It is also a header the recipient can
   read, so it never says more than the tenant key.
3. **Public receipts with `tenant_column: true`**, where webhooks work
   unchanged. For a host whose only reason to go per-tenant was data residency,
   this may be the right trade.

Whichever it is, a webhook that names a tenant its receipt was not sent from
finds nothing: the message id exists in one schema only. Nothing is fanned out
across schemas looking for it.

### 7. `job_args: :minimal` is now your default

`oban_jobs` is **not** per tenant — it is one table in the public schema. The
email job's args used to carry the rendered subject and bodies, which for a
per-tenant host would be the one place a tenant's letter leaves its own schema.
So when receipts are per tenant, the args carry ids only and the worker reads
the message from the receipt:

```elixir
config :ash_dispatch, job_args: :minimal   # the default when receipts are per tenant
config :ash_dispatch, job_args: :full      # the old shape, if you want it back
```

It costs one receipt read per send on the first attempt. Every retry already
paid it.

## Only the `tenant` column

For a host that keeps receipts in the public schema and wants to know which
tenant a receipt was for:

```elixir
use AshDispatch.Resources.DeliveryReceipt.Base,
  repo: MyApp.Repo,
  domain: MyApp.Deliveries,
  notification_resource: MyApp.Notifications.Notification,
  tenant_column: true
```

```bash
mix ash.codegen add_receipt_tenant
mix ash.migrate
```

One nullable `string` column, filled from the dispatch's tenant. Existing rows
need no backfill, nothing else changes, and `Notification.Base` and
`Preference.Base` have had the same column since 0.9.0.

## What a host that does nothing sees

Nothing. `AshDispatch.Tenancy.opts/2` answers `[]` for a resource that declares
no multitenancy, so every read and write the library makes is the one it made
in 0.9.3, argument for argument. The `Base` macros emit no `multitenancy` block
and no new column unless asked. `job_args` stays `:full`. The cron plan stays
one pass with no tenant. `:tenants` is never consulted.

That is asserted rather than claimed: `test/tenancy/compatibility_test.exs`
spies on the resources and fails if one of them is ever handed a tenant, and
the 0.9.3 suite runs unchanged.

## Release candidate

0.9.4's per-tenant path is new and wants a run in a real multi-tenant
application before it is called final. The parts a first host should watch:
the first `mix ash.codegen` after switching a resource over, the cron fan-out
under a few hundred tenants, and whatever its provider does with the tenant tag
if it uses one.
