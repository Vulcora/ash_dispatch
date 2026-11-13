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

### If your tenants are structs

They can be. `Ash.ToTenant` is what turns one into a schema name, and its own
documentation teaches the shape where the schema is **not** the struct's `:id`:

```elixir
defimpl Ash.ToTenant, for: MyApp.Accounts.Organisation do
  def to_tenant(%{id: id}, _resource), do: "org_#{id}"
end
```

Everything the library has to serialise and hand back to Ash — an Oban job's
args, the cron fan-out's args, the scrub's `prefix:`, the outgoing tenant tag,
the comparison in `AshDispatch.Tenants` — goes through that protocol
(`AshDispatch.Tenancy.prefix/2`). So `tenant: org` works wherever a string
works.

The `tenant` **column** is a different thing and still holds
`AshDispatch.Context.tenant_key/1`: a struct's `:id`. For a tenant whose
schema is not its id those two strings differ, and a report that joins the
column against your schema names needs your own mapping. Making the column
hold the schema name is a 0.10.0 change — it would rewrite what is already
stored.

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
- a tenant the **library** reads back, rather than one you passed it, is held
  against `c:AshDispatch.Tenants.known?/1` before it reaches a query. A tenant
  is a Postgres schema name.

### Exactly which tenants the library checks

Three, and they are the three the library did not get from your own code:

| Where it came from | Checked |
|---|---|
| An Oban job's args (`AshDispatch.Tenancy.from_job_args/1`) | yes |
| A provider webhook's tenant tag | yes, and refused when it cannot be checked |
| A provider webhook's route param (`process_webhook(params, tenant: ...)`) | yes, and refused when it cannot be checked and your receipts are per tenant |
| A fanned-out cron job's args | yes |
| `:tenant` on `NotificationLoader.load_recent/2`, `unread_count/1`, `mark_as_read/2`, `CounterLoader.load_counters_for_user/2`, `UserPreference.Resource.put/3`, `Preview.render/3`, the LiveView assign | **no** |

The last row is deliberate and is yours. Those are calls your own code makes,
inside your own request, with a tenant you have already authorised — the same
value you pass to your own `Ash` calls. Holding it against `c:AshDispatch.Tenants.all/0`
would add a query per bell render and per settings page, and would make the
library refuse a tenant your own queries accept (one that exists but is not
`active == true` in the `all/0` above, say).

So if any of those takes a tenant straight from a request parameter or a
socket assign, check it where you check everything else about that request.
`AshDispatch.Tenants.check/1` is public if you want the library's answer:

```elixir
with :ok <- AshDispatch.Tenants.check(params["tenant"]) do
  NotificationLoader.load_recent(user.id, tenant: params["tenant"])
end
```

`UserPreference.Resource.put/3` is the sharpest of them: `attrs.tenant`
becomes the schema a row is written to, so a LiveView param wired straight
into it is a cross-tenant write.

### `c:AshDispatch.Tenants.known?/1`

Optional, and **strongly recommended once your webhook endpoint is public**.
Without it, membership in `all/0` is the answer, and `all/0` runs once per
check — which is once per send job and once per unauthenticated POST to the
webhook endpoint, the one place in the library an outsider can trigger work.
With it, nothing is listed:

```elixir
@impl true
def known?(tenant) do
  MyApp.Accounts.Organisation
  |> Ash.Query.filter(schema == ^tenant and active == true)
  |> Ash.exists?(authorize?: false)
end
```

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
   provider. It needs `:tenants` like the others: a path segment is a value
   from outside, and with per-tenant receipts it is a Postgres schema name.
   Without that configuration this path is refused rather than trusted.
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

A refusal and "no such message" are the same answer, `{:error, :not_found}`.
They used to differ, which made the endpoint a list of your customers to
anyone who could POST to it. Your log keeps the distinction. Do not hand the
reason back in the response body — the controller example in
`AshDispatch.WebhookHandlers.Resend` shows what to return instead.

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

Two consequences worth knowing:

- the worker refuses to send a letter the job does not carry and the receipt
  does not hold either, and records the receipt `:failed_permanent` with the
  reason. Under `:full` the job carries the letter, so this only bites when
  there is nothing to send;
- `from` is addressing, not message content, so it comes from
  `:default_from_name`/`:default_from_email` as it does under `:full`. An
  event that sets its own still wins.

## `uuid_generate_v7()` must exist in the database

Two of the library's resources have a **UUID v7** primary key:
`AshDispatch.Resources.Notification.Base` and
`AshDispatch.Resources.Preference.Base`, both since 0.9.0. A v7 id carries its
timestamp in its leading bits, so rows written in order are stored in order —
which is what an inbox query (`WHERE user_id = … ORDER BY inserted_at DESC`)
wants, and which a random v4 id costs you in index churn. The delivery receipt
is on a plain v4 key and is unaffected.

`mix ash.codegen` turns a v7 key into this:

```elixir
add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true
```

Postgres has no `uuid_generate_v7()` of its own before version 18. **ash_postgres
creates it** — in its `ash-functions` migration, and only for a repo whose
`installed_extensions/0` lists `"ash-functions"`:

```elixir
defmodule MyApp.Repo do
  use AshPostgres.Repo, otp_app: :my_app

  def installed_extensions, do: ["ash-functions"]
end
```

Where the function is missing, `CREATE TABLE` fails. Nothing warns you at
compile time, the migration looks ordinary, and the error arrives from the
database.

### How to check

```sql
SELECT to_regprocedure('public.uuid_generate_v7()');
```

`NULL` means it is not there. `mix ash_dispatch.install` runs the same check
against your repo's source and says so.

### The migration to add it

```bash
mix ash.codegen install_ash_functions
mix ash.migrate
```

That is the ordinary route and the one to take: ash_postgres notices the
extension is newly requested and writes the migration for it, together with
the other functions Ash expects (`ash_elixir_or`, `ash_trim_whitespace`,
`ash_raise_error` — the last of which a receipt's state machine needs anyway).

If you cannot run `ash.codegen` — a schema someone else owns, a migration
written by hand — the function is one statement:

```elixir
defmodule MyApp.Repo.Migrations.AddUuidGenerateV7 do
  use Ecto.Migration

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION uuid_generate_v7()
    RETURNS UUID
    AS $$
    DECLARE
      timestamp    TIMESTAMPTZ;
      microseconds INT;
    BEGIN
      timestamp    = clock_timestamp();
      microseconds = (cast(extract(microseconds FROM timestamp)::INT - (floor(extract(milliseconds FROM timestamp))::INT * 1000) AS DOUBLE PRECISION) * 4.096)::INT;

      RETURN encode(
        set_byte(
          set_byte(
            overlay(uuid_send(gen_random_uuid()) placing substring(int8send(floor(extract(epoch FROM timestamp) * 1000)::BIGINT) FROM 3) FROM 1 FOR 6
          ),
          6, (b'0111' || (microseconds >> 8)::bit(4))::bit(8)::int
        ),
        7, microseconds::bit(8)::int
      ),
      'hex')::UUID;
    END
    $$
    LANGUAGE PLPGSQL
    SET search_path = ''
    VOLATILE;
    """)
  end

  def down, do: execute("DROP FUNCTION IF EXISTS uuid_generate_v7()")
end
```

That is ash_postgres's own definition, copied; keep taking it from
ash_postgres rather than from here if the two ever differ. On Postgres 18 and
later ash_postgres uses the built-in `uuidv7()` instead and creates nothing —
tell it which server you are on with `min_pg_version/0` on the repo.

### If you create a tenant's tables when the tenant is created

This is where it bites hardest, and it is the reason the section exists.

The function is created **once, in one schema** — the repo's default prefix,
normally `public`. A `CREATE TABLE` in a tenant's schema resolves
`uuid_generate_v7()` against the `search_path` of whoever runs it. If your
tenant-creation code sets the search path to the new schema alone, the
function is not visible, `CREATE TABLE` fails, and **no tenant can be
created** — the tables are made at sign-up, so the failure is in your sign-up
path rather than in a deploy.

So either:

- install `ash-functions` **before** the first tenant, and leave `public` on
  the search path of the connection that creates a tenant's tables (which is
  `mix ash.migrate`'s own behaviour); or
- schema-qualify it, if you write the DDL yourself: `DEFAULT
  public.uuid_generate_v7()`; or
- do not use a v7 key at all, below.

### Or: ask the base for a v4 key

A host that cannot define functions in its database — a managed instance, a
schema it does not own — can say so, and nothing about your database has to
change:

```elixir
defmodule MyApp.Notifications.Notification do
  use AshDispatch.Resources.Notification.Base,
    repo: MyApp.Repo,
    domain: MyApp.Notifications,
    multitenancy: :context,
    primary_key: :uuid
end
```

`:uuid` gives `uuid_primary_key :id`, whose migration default is
`gen_random_uuid()` — built into Postgres 13 and later, in every schema. The
option is on all three bases (`Notification.Base` and `Preference.Base`
default to `:uuid_v7`, `DeliveryReceipt.Base` to `:uuid`) and on
`AshDispatch.Setup`, which passes it through.

**Set it before you generate the first migration.** Both kinds store the same
column — `:uuid_v7`'s storage type *is* `uuid` — so switching only changes the
column's DEFAULT, and `mix ash.codegen` will write you an `ALTER COLUMN … SET
DEFAULT` for a table that already exists. Ids already written keep working
either way; you lose the ordering property for rows written after the switch,
not the rows themselves.

Nothing here changed a default. A host that does not pass `primary_key:` gets
exactly the key it got in 0.9.3 and 0.9.4-rc.1.

## While you are deploying

A 0.9.3 node that picks up a 0.9.4 fanned-out cron job ignores
`args["tenant"]` and runs the public pass instead — which finds nothing and
reports success. Harmless, and it stops the moment every node is on 0.9.4;
worth knowing if a rolling deploy leaves one node behind over a cron window.

In the other direction a 0.9.3 job carries no `"tenant"`, reads back as `nil`,
and behaves exactly as it did, which is what makes this safe to deploy while
jobs are in flight.

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
spies on the resources and fails if one of them is ever handed a tenant, an
AST walk over `lib/` fails if a tenant reaches Ash or the repo without going
through `AshDispatch.Tenancy`, and the 0.9.3 suite runs unchanged.

## Release candidate

0.9.4's per-tenant path is new and wants a run in a real multi-tenant
application before it is called final. The parts a first host should watch:
the first `mix ash.codegen` after switching a resource over, the cron fan-out
under a few hundred tenants, and whatever its provider does with the tenant tag
if it uses one.

An independent review of rc.0 found eleven things, including three that lost
mail on a host doing exactly what this page says. They are fixed in rc.1 — see
the CHANGELOG for what each of them was.

rc.2 is the first report from a host actually running it. Everything on this
page behaved as written; three things that were not on it did not. Two of them
are now: the `uuid_generate_v7()` section above, which is the one that stops a
tenant being created at all, and — in the *Previews and testing* guide — whose
clock the library's timestamps come from. The third was the generated
TypeScript client, which could not be turned off and now can
(`config :ash_dispatch, sdk: false`).
