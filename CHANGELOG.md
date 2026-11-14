# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.9.4-rc.4] - 2026-11-14

### What the first host found in rc.2

rc.2 answered three things the first per-tenant host reported (#50). It took
rc.2 and came back with three more: one of the two answers did not catch the
case it was written for, the other was on in every configuration, and the
third — the one rc.2 declined to build until somebody wanted it — is now
wanted. `sdk: false` worked exactly as documented, and nothing else moved
between rc.1 and rc.2.

1. **The installer's `uuid_generate_v7()` warning could not see the host's
   case.** It looked for the string `"ash-functions"` in the repo's source.
   The host's repo listed it and the function was missing anyway: ash_postgres
   emits `uuid_generate_v7()` only when it is *not* relying on the server's
   own, which it derives from `min_pg_version/0` (`major >= 18`), and that
   host's `ash-functions` migration had been generated while the answer was
   18. Lowering it to 17 afterwards does not rewrite a file already on disk.
2. **`sdk: :if_events` was `:always`** for any host using
   `Notification.Base`. The base declares the `unread_notifications` counter,
   rc.2 counted every counter it found, and the host saw
   `Found 0 events, 1 counters` while declaring none.
3. **The timestamps the library writes from Elixir are now on a clock the host
   can supply.** rc.2 wrote this down (BACKLOG 13) rather than building it,
   because a clock nothing persisted reads is worse than no clock. A host has
   asked.

### Added

- **`AshDispatch.Doctor`**, the `uuid_generate_v7()` check that asks the
  database — which is the only check that can settle it. `check/1` returns
  `:ok` or `{:error, %AshDispatch.Doctor.Error{}}` whose message carries the
  exact migration to add; `check!/1` raises it. For a boot that should refuse
  to start, or a test:

      test "the database has what ash_dispatch's tables need" do
        assert :ok = AshDispatch.Doctor.check()
      end

  It asks for the function **this** host's migrations name — read from the
  repo the way ash_postgres decides it, `use_builtin_uuidv7_function?/0` — and
  for the one an existing table's column `DEFAULT` names when the two have
  come apart. Where the function exists in a schema this connection cannot
  resolve, it says which schema and what the `search_path` is, which is the
  per-tenant trap rather than a missing migration. It opens no connection of
  its own, so the repo must be started.
- **`mix ash_dispatch.doctor`**, the same check from a shell, exit 1 on a
  problem, for a deploy script or a CI job.
- **`config :ash_dispatch, clock: {Module, :function, args}`**, read by
  `AshDispatch.Clock`, and **nothing else in the library asks what time it
  is**. Unset it is `DateTime.utc_now/0`, byte-for-byte what every release
  before this one did. `clock: MyApp.Clock` means that module's `utc_now/0`,
  and any 0-arity function is accepted.

  Through it: `occurred_at`, `sent_at`, `read_at`, `seen_at`, `archived_at`,
  `last_retry_at`, the cut-off `RetryFailedDeliveries` compares
  `last_retry_at` against, both cut-offs in `ScrubSensitiveContent`,
  `AshDispatch.Workers.Stranded`'s staleness bounds,
  `AshDispatch.Context`'s `:now` (so the broadcast payload's timestamp comes
  from it without anyone passing anything), a webhook envelope's `sent_at`
  and a Resend event's `webhook_received_at`.

  **Not** through it, in both cases on purpose and both written down in
  `AshDispatch.Clock`'s moduledoc: `inserted_at`/`updated_at`, which are
  Ash's and whose default is the one value ash_postgres turns into a column
  `DEFAULT` (0.10.0, BACKLOG 13); and the Resend webhook's timestamp
  tolerance, which compares our wall clock against the *sender's* to reject a
  replayed signature — a frozen clock would let a stale one through. The
  "Generated at" banners in the code generators are build-time text and are
  not a stored or compared value.

### Changed

- **`mix ash_dispatch.install` reads three things about `uuid_generate_v7()`
  instead of one**, all from the project's files and still with no database
  connection: whether `installed_extensions/0` lists `"ash-functions"`, what
  `min_pg_version/0` answers, and whether a migration that installs Ash's
  functions defines the function (`FUNCTION uuid_generate_v7` — the
  definition, not the `fragment("uuid_generate_v7()")` column default that
  every table migration mentions). It warns in three distinct cases now,
  including the host's: the extension listed, the answer lowered to 17, and
  the migration still without the function. **Every notice says plainly that
  listing the extension is not sufficient** and gives
  `SELECT to_regprocedure('public.uuid_generate_v7()')` as the authoritative
  check, with `AshDispatch.Doctor` beside it.
- **`sdk: :if_events` counts what the host declared.** Each `Base` macro now
  states what it declared on the resource it builds
  (`AshDispatch.Resources.Base`), and the generator discounts it. A host with
  the three bases and nothing else generates nothing; one event, or one
  counter of its own, and the client appears. `mix ash_dispatch.gen --verbose`
  says how many of the counters it found came from the bases.

  **`true` and `false` are unchanged.** That matters here: the generated
  `NotificationBell` and `useNotifications` read `unread_notifications`, so a
  host that uses the in-app bell needs the client **for** the base's counter
  and `sdk: true` (the default) is how it says so. `:if_events` is the wrong
  switch for that host — an inbox is not an event, and `:if_events` would
  also start writing the client the day it declares its first one. The Code
  Generation guide has a table of the three wishes and their spellings.

### Documentation

- **The Tenancy guide says that listing the extension is not sufficient**, in
  those words, and gives the SQL check as authoritative. A new section
  explains why a repo that lists `"ash-functions"` can lack the function:
  ash_postgres's `use_builtin_uuidv7_function?/0`, the fact that the
  `ash-functions` migration is generated once, and that
  `mix igniter.install ash_postgres` fills `min_pg_version/0` in from the
  *local* `postgres -V` — which is how 18 gets written into a project that
  deploys against 17.
- **The install guide's Prerequisites say the same**, with
  `mix ash_dispatch.doctor` and `AshDispatch.Doctor.check!/1` next to the SQL.
- **The testing guide documents the clock**, with a frozen-clock module a host
  can copy, a test asserting on the instant it chose, and a second one moving
  the clock an hour so `RetryFailedDeliveries` finds a receipt without
  waiting. The table of "whose clock" now has a row a host can answer *yes*
  to, and says why the other two rows still cannot move.
- **The changelog's rc.2 entry carries a correction**: "`:if_events` … has
  events, counters … in your resources" was the wrong sentence for what rc.2
  shipped.
- **BACKLOG 13** records the migration-free half as done and keeps the two
  halves that need 0.10.0 — `inserted_at`/`updated_at` on the same clock, and
  `timestamptz` columns — with the reason each one is a migration. Both are
  now only the migration question: the clock they would read already exists.

### Compatibility

Still a patch. No migration, no column changed, and no default changed for a
host that has not opted in. `occurred_at` moved onto the clock without
touching its migration, because its default was already an `{m, f, a}` tuple
and ash_postgres derives a column `DEFAULT` only from a function capture — a
test pins that, and pins that `inserted_at`/`updated_at` still carry Ash's
own `&DateTime.utc_now/0`.

Upgrading from rc.2 or rc.3 and setting none of the new options gives you what
rc.3 gave you, with one exception, which is the fix: `sdk: :if_events` on a
host that declared nothing of its own now generates nothing, where before it
generated the client. A host that wants the client should say `sdk: true`.

1147 tests pass with a database and 1038 without, none failing (1102 and 995
on rc.3; 45 added).

## [0.9.4-rc.3] - 2026-11-14

### Slack and Discord webhook URLs stay out of the job table and the log

A Slack or Discord webhook URL is a credential: whoever has it can post to the
channel. Until now it was copied into `oban_jobs.args` (`"webhook_url"`), where
it outlives the job, and `AshDispatch.Workers.SendWebhook` logged it on every
outcome (`url=…` on success, on 4xx/5xx and on network errors, and in full in
the debug line).

- **`metadata.webhook_url_env` for `:slack` and `:discord`**, the option
  `:webhook` got in 0.9.4. The job args carry the variable's NAME
  (`"webhook_url_env"`) and no URL; the worker reads the value when it sends.
  A rotated URL takes effect for jobs already queued, and nothing needs a
  recompile. An unset variable skips the receipt at dispatch with
  `"webhook_url_env NAME is not set"`, and fails (retryably) at send time with
  the same reason — never a value.
- **No log line carries the URL.** `SendWebhook` logs
  `AshDispatch.Transports.WebhookUrl.mask/1` (scheme and host) everywhere, and
  scrubs the URL out of logged response bodies and errors. This applies to
  every webhook-based transport, including an explicit `webhook_url`.
- `Slack.job_args/3` and `Discord.job_args/3` are public, so the shape that
  lands in `oban_jobs.args` can be tested without Oban.
- `config :ash_dispatch, AshDispatch.Workers.SendWebhook, req_options: [...]`
  is passed into `Req.post/2`, as `:req_options` already is for Elks.

Unchanged: a channel with neither `webhook_url_env` nor a URL is `:skipped`
with `"No webhook_url configured"`; an explicit `webhook_url` still travels in
the job args (it is compiled into the application already). The generic
`:webhook` transport still resolves `webhook_url_env` at dispatch, because its
signature binds the URL's path at enqueue time.

## [0.9.4-rc.2] - 2026-11-13

### What the first per-tenant host found

rc.0 and rc.1 were read by people who had not built the library. rc.2 is the
first report from someone *running* it: one Postgres schema per tenant, the
generated TypeScript client in use, in production. Everything in the Tenancy
guide behaved as documented. Three things that are not in it did not (#50).

None of them is a defect in what the library does. Two are things it does
without being asked and gives no way to decline; the third is a fact about its
own tables that nobody wrote down. That is the shape of most of what a first
host finds, and it is worth saying out loud, because "no bugs" and "nothing to
fix" are not the same sentence.

1. **The React/TypeScript SDK could not be turned off.** It is generated as
   soon as `config :ash_typescript, output_file:` is set — which a host may
   have set for its own RPC types, with no interest in this library's client.
   A host with no AshDispatch events got thirteen files (channel, store, three
   `.tsx` components, hooks, README), a `.prettierignore` section, and warnings
   about `zustand` and `phoenix`, which it does not depend on. The obvious
   guess, `sdk_output_path: false`, went through an `||` chain, so `false`
   read as "not configured", the path was derived from ash_typescript's
   `output_file` instead, and the files were written anyway. Deleting them
   then failed `--check` in CI: files you did not want, and a job that insists
   on them.
2. **`uuid_v7_primary_key` needs `uuid_generate_v7()`, and the guides never
   said so.** `Notification.Base` and `Preference.Base` have had a v7 key
   since 0.9.0, so `mix ash.codegen` writes
   `default: fragment("uuid_generate_v7()")` into their migration. Postgres
   has no such function before 18 — ash_postgres creates it, in its
   `ash-functions` migration, and only for a repo whose
   `installed_extensions/0` asks for it. Where it is missing, `CREATE TABLE`
   fails. For this host that is not a failed deploy: it creates each tenant's
   tables when the tenant is created, so no tenant could be created at all.
3. **The library's timestamps are not on the host's clock.** They are
   `utc_datetime_usec` — `timestamp` *without* time zone — in an app that is
   `timestamptz` everywhere, and their values come from the BEAM inside Ash
   and inside this library, not from the one module the host routes time
   through. So a test that freezes time cannot pin them.

### Added

- **An off switch for the generated SDK.** `config :ash_dispatch, sdk: false`
  generates nothing — no client, no `.prettierignore` section, no
  peer-dependency warning — and `mix ash.codegen --check` passes with none of
  those files on disk. `sdk_output_path: false` is read as the same thing
  rather than as "unset". Both keys are also read in the app-scoped spelling
  (`config :my_app, ash_dispatch: [...]`).
- **`config :ash_dispatch, sdk: :if_events`** generates the SDK only when the
  app has events, counters, a `resource_meta` or an `entity_changes` block.
  **Opt-in, not the default**: a host with none of those has been getting the
  client's static files since 0.8.0, and a patch release does not stop writing
  files a host already has. Set it, run `mix ash.codegen`, delete the files
  once.
  **Correction (0.9.4-rc.4):** "in your resources" was the wrong sentence.
  As shipped in rc.2 this counted every counter it found, and
  `Notification.Base` declares one — so `:if_events` was `:always` for every
  host with an in-app inbox. It means "declared by you" from rc.4 on.
- **`primary_key:` on all three `Base` macros** (`:uuid_v7` or `:uuid`), and
  through `AshDispatch.Setup`, which passes it on. For a host whose database
  will not define functions: `:uuid` means `gen_random_uuid()`, built into
  Postgres 13 and later, in every schema. **No default moved** —
  `Notification.Base` and `Preference.Base` are still `:uuid_v7`,
  `DeliveryReceipt.Base` is still `:uuid`. Both kinds store a `uuid` column,
  so the option changes the column's DEFAULT and nothing else.
- **`mix ash_dispatch.install` warns when the repo does not install
  `ash-functions`**, with the SQL to check the database
  (`SELECT to_regprocedure('public.uuid_generate_v7()')`), the
  `installed_extensions/0` line that fixes it, and `primary_key: :uuid` as the
  alternative. The check is the repo's own source: no database connection.

### Documentation

- **The Tenancy guide has a `uuid_generate_v7()` section**: which resources
  have a v7 key and why, what the migration contains, how to check, how to
  install it through `ash.codegen`, the statement to run by hand when that is
  not available, and the part that only bites a per-tenant host — the function
  lives in one schema, and a `CREATE TABLE` in a tenant's schema resolves it
  against the creating connection's `search_path`.
- **The install guide says it in Prerequisites**, beside the PostgreSQL 15
  floor, where a reader who has read nothing else will meet it.
- **The Code Generation and TypeScript SDK guides document the off switch.**
- **The testing guide says whose clock the library's timestamps come from**:
  `utc_datetime_usec` columns; a `DEFAULT (now() AT TIME ZONE 'utc')` that is
  a safety net for an INSERT that does not go through Ash, not where the value
  normally comes from; Ash filling `inserted_at`/`updated_at` from the BEAM
  while building the changeset; `writable?: false`, so an action cannot be
  given them. Assert on ordering or a window, not on an instant.
- **BACKLOG 13** carries the rest of the timestamp question, split by cost.
  The values written from Elixir could be routed through a configurable clock
  without touching a column — `AshDispatch.Context` already carries `:now`, so
  half the seam exists — and that would fit inside a 0.9.x patch if a host
  asks for it. Moving `inserted_at`/`updated_at` to such a clock, or the
  columns to `timestamptz`, is 0.10.0: the first changes what ash_postgres
  writes as the column DEFAULT unless `migration_defaults` is pinned to hold
  it still, and the second is an `ALTER COLUMN … TYPE`, per tenant.

### Compatibility

A patch, under the same rule as every 0.9.x before it: no migration, and no
default changed for a host that has not opted in. A host that upgrades from
rc.1 and sets none of the new options gets byte-for-byte what rc.1 gave it —
the same SDK files, the same primary keys, the same timestamps. The suite that
passed on rc.1 passes unchanged, with 26 tests added for what is new.

## [0.9.4-rc.1] - 2026-11-13

### What rc.0 got wrong

rc.0 shipped as a release candidate asking for exactly this: a reading by
someone who had not built it. An independent review found eleven things. Three
of them lose mail on a host that does precisely what the Tenancy guide says,
and they are all small, local mistakes — the kind a suite of 974 tests cannot
see because every one of them is about a shape the fixtures did not have.

Written plainly, because the next reader deserves to know what was wrong and
not only what is right now:

1. **A struct tenant was reduced to its `:id`, and every send for it was
   cancelled.** `Ash.ToTenant` decides which schema a tenant's rows live in,
   and its own documentation teaches the shape where the schema is not the
   struct's `:id` (`"org_" <> id`, `org.schema`). The *write* side was right —
   it hands the term to Ash, which applies the protocol. Every place rc.0
   **serialised** a tenant used `AshDispatch.Context.tenant_key/1`, which
   answers the `tenant` column's string: the Oban job's args, the cron
   fan-out's args, the scrub's raw `prefix:`, the outgoing tenant tag and
   `AshDispatch.Tenants`' own comparison. So a dispatch with
   `tenant: %Organisation{id: "a"}` wrote its receipt into `org_a` correctly,
   told the job `"a"`, and the worker cancelled the job — a cancelled Oban job
   is a delivery lost for good, and every rescue path rebuilds the same args.
   The scrub's `update_all(prefix: "a")` raised, so no tenant's sensitive
   bodies were ever scrubbed: the exact bug 0.9.4 exists to fix. And
   `Tenants.check/1` was no protection at all for such a host, because it
   reduced both sides of its comparison and so approved precisely the strings
   that cannot be read. Everything that becomes a schema name goes through
   `AshDispatch.Tenancy.prefix/2` now. A tenant struct with no `:id` raised
   `Protocol.UndefinedError` from the middle of a dispatch; it names the
   problem now (`AshDispatch.Tenancy.UnsupportedTenantError`).
2. **A tenant mid-migration was cancelled instead of retried.**
   `missing_schema?/1` matched `42P01`/`undefined_table`, which is what
   Postgres says for a schema that exists but whose tables are not there
   *yet*: the normal state of a tenant between `create schema` and
   `mix ash.migrate`, and of every tenant during a deploy that adds a table.
   Every send enqueued in that window was cancelled permanently with its
   receipt left `:scheduled`. Only `3F000` is cancelled now. The free-text
   arms are gone too — they searched the error's message, so a nested error
   about `public.oban_jobs` was read as a missing tenant.
3. **Four reads of the host's own resources were never threaded, and all four
   fail closed.** The `should_send_filter` query, `CounterLoader`'s audience
   check, `CounterHandler`'s `load_and_traverse_path/3` (which was *given* a
   `tenant` parameter nobody passed) and the context `CounterHandler` builds
   for a filter-based audience. Each raised `TenantRequired`, each was rescued
   to "no", and the result was dispatches skipped and counters zeroed with
   nothing but a log line. The design document's hand-kept list of 87 call
   sites is replaced by an AST walk over `lib/` that fails the build.
4. **A webhook's route tenant was used unchecked, and the endpoint said which
   tenants exist.** A path segment comes from outside like a provider's tag
   does; rc.0 passed `allow_unchecked?: true` for it, so with `:tenants`
   absent — the setup the guide recommends and never said needed `:tenants` —
   the string in `POST /webhooks/resend/:tenant` went into a Postgres prefix
   with no check. Separately, `{:error, :not_found}` and
   `{:error, :unknown_tenant}` were distinguishable, so an unauthenticated
   POST per candidate name enumerated the host's schemas, which is to say its
   customers — and the controller example in the module's own docs handed
   `inspect(reason)` back in the response body. One answer for both now, with
   the distinction in the log; the refusal log is a `warning`, once a minute
   per reason, and no longer names the tenant the caller chose.
5. **`job_args: :minimal` sent an empty letter and recorded it `:sent`.** The
   guard written for "the job carries no body, so the receipt is all there is"
   was keyed on `sensitive_content`, and `:minimal` — the default when
   receipts are per tenant — made that args shape universal. A receipt whose
   bodies had gone was delivered as `subject: nil, text_body: nil,
   html_body: nil` and marked `:sent`. The guard asks the args now.
6. **The From display name was dropped under `:minimal`.** `:full` args carry
   `%{"name" => ..., "email" => ...}`; `:minimal` args carry no `"from"`, and
   the fallback answered the bare address. So a host that switched receipts to
   per-tenant schemas started sending `noreply@acme.test` where it had sent
   `Acme Bookings <noreply@acme.test>`. Also wrong for a sensitive event's job
   since 0.8.7.
7. **`tenant: nil` was written into a column the host owns.** The dispatcher
   added the key unconditionally and relied on `skip_unknown_inputs` to drop
   it. That option drops an input the action does not accept; it does not drop
   one it does — and Ash applies an attribute's default only when the input is
   *absent*. A host with a receipt resource of its own that already had a
   `tenant` attribute with a default had it overwritten with `nil` on every
   dispatch, having opted into nothing.
8. **`Tenancy.of/1` read Ash's metadata without asking the resource.** Ash
   records the tenant it was given on every action, for any resource,
   multitenant or not. So a host whose app passes `tenant:` to every `Ash`
   call handed the library receipts carrying one, it went into the job args,
   and `Tenants.check/1` could **cancel the job** — for a receipt in the
   public schema, on a host that had never heard of any of this.
9. **The cron fan-out had no uniqueness and no honest result.** The design
   document gives "Oban's `unique` keeps a slow tenant from being enqueued
   twice" as one of three reasons for the fan-out; it was never built, so
   every tick added one more pass per tenant whatever was still queued. And
   `fan_out/2` answered `:ok` when it had enqueued nothing, so a run that did
   nothing was green in Oban.
10. **The "structural guards" proved less than they claimed.** Two text
    searches stood in for "every read and write the library makes takes its
    tenant from `AshDispatch.Tenancy`". Seven ordinary spellings got past both
    — `Ash.Query.set_tenant/2`, a tenant in a variable, a multi-line call, a
    `)` in the first argument, the `Ash.Query`/`Ash.Changeset` constructors,
    `apply/3`, and the raw `prefix:` neither search mentioned. One of them
    also reported prose in a `@moduledoc` as a call site. It is an AST walk
    now, and what the walk catches is itself asserted.
11. **`:tenants` guarded three outside paths, and the guide implied every
    `:tenant`.** The guide now says exactly which tenants the library checks —
    the ones it reads back from an Oban job, a provider payload or a webhook
    route — and that the `:tenant` a host passes to a loader is the host's own
    to validate, with `AshDispatch.Tenants.check/1` public for it.
    `c:AshDispatch.Tenants.known?/1` is documented as strongly recommended
    once the webhook endpoint is public, and `check/1` now asks the host's
    source at most once per call by construction rather than by how the calls
    happened to nest.

Smaller things from the same review: a dispatch with no tenant only consulted
the receipt resource, so a host that switched only `Notification.Base` or
`Preference.Base` to `:context` got a retry loop instead of the loud refusal;
a fanned-out cron job whose tenant could no longer be checked ran in silence;
`Tenants.all/0` and `check/1` rescued exceptions but not an exit, so a
`DBConnection` timeout in a host's `all/0` took the cron entry job down;
`ScrubSensitiveContent` had an unreachable `perform/1` clause; the cancelled
send job's `Logger.error` is a `warning`; and `unique: [keys: [:receipt_id]]`
on the send workers names the tenant too, since a receipt id is unique per
schema and not across them.

### Changed

- **An email with nothing in it is refused rather than sent.** If the job
  carries no body and the receipt has no body and no subject either, the
  worker refuses, records the receipt `:failed_permanent` with the reason, and
  does not call the provider. This can reach a host on the default `:full`
  args, in one case: an event that renders no subject **and** no body used to
  go out empty and be recorded `:sent`. A subject with no body still sends.
- **`WebhookHandlers.Resend.process_webhook/2` answers `{:error, :not_found}`
  where rc.0 answered `{:error, :unknown_tenant}`**, and refuses a route
  tenant it cannot check when receipts are per tenant. Both return values are
  new in rc.0, so nothing released depends on them.
- **`Tenancy.Cron.fan_out/2` answers `{:error, reason}`** when it could not
  enqueue a single pass. A partial failure is still `:ok`.
- **The From of an email that sets none carries the configured display name**
  under every args shape, including a sensitive event's job (wrong since
  0.8.7) and a retry built from the receipt alone.

### Added

- **`AshDispatch.Tenancy.prefix/2`** and `receipt_prefix/1` — a tenant as the
  schema name `Ash.ToTenant` resolves it to. The one answer every serialising
  path in the library agrees on. For a string, atom or integer tenant the
  protocol is the identity, so this changes nothing for a host that names its
  tenants with strings.
- **`AshDispatch.Tenancy.UnsupportedTenantError`** — a named error for a
  tenant the `tenant` column cannot hold, instead of a bare
  `Protocol.UndefinedError` from wherever the library happened to be.
- **`AshDispatch.Log.throttled/3`** — runs a log line at most once per window
  per key, for the lines an outsider can provoke.
- **`AshDispatch.Tenancy.Cron.job/2`** — the job the fan-out enqueues for one
  tenant, so its uniqueness can be asserted on the thing that is inserted.

### Fixed

Everything in *What rc.0 got wrong* above. Nothing in it is reachable without
`multitenancy: :context` on one of the three bases, except findings 7 and 8,
which reach a host that opted into nothing, and the empty-letter guard under
*Changed*.

## [0.9.4-rc.0] - 2026-11-12

### Release candidate

**The per-tenant path below wants a run in a real multi-tenant application
before this is called final.** Nothing in it is reachable without switching it
on, and the compatibility half is held to the whole 0.9.3 suite plus a test
that fails if any resource without multitenancy is ever handed a tenant — but
"two tenants in a test database" is not the same as a production schema per
customer, a `mix ash.codegen` against real tables, or a cron fan-out over a few
hundred tenants. A first host should watch those three.

### Added

- **The tenant through the whole flow.** The library knew what a tenant was
  since 0.8.8 and stored one since 0.9.0, but every read and write it made, it
  made without one. A host with `multitenancy strategy :context` and one
  Postgres schema per tenant therefore wrote its receipts into `public`, and
  `ScrubSensitiveContent` never reached a tenant schema at all.

  ```elixir
  use AshDispatch.Resources.DeliveryReceipt.Base,
    repo: MyApp.Repo,
    domain: MyApp.Deliveries,
    notification_resource: MyApp.Notifications.Notification,
    multitenancy: :context

  config :ash_dispatch, tenants: MyApp.Tenants
  ```

  `multitenancy: :context` on `DeliveryReceipt.Base`, `Notification.Base` and
  `Preference.Base` declares `strategy :context` with `global? false`, and the
  tenant is then carried dispatch → the Oban job's args → the recipient
  resolver → the send → the receipt → the provider webhook → the cron → the
  preview. `{:context, global?: true}` is there for a host with both
  tenant-scoped and system-wide events. Needs a migration of your own and
  `:tenants`; see the new [Tenancy](tenancy.html) guide, which is also the
  upgrade guide.
- **`AshDispatch.Tenants`** — the one question the library cannot answer for
  itself. A host implements `c:AshDispatch.Tenants.all/0` (and
  `c:AshDispatch.Tenants.known?/1` when `all/0` is too expensive to ask per
  webhook); `{module, function}`, `{module, function, args}` and a
  zero-argument function work too. Needed when receipts are per tenant: the two
  scheduled workers run across tenants, and a tenant that arrives **from
  outside** is held against it before it reaches a query, because a tenant is a
  Postgres schema name.
- **`tenant_column: true`** on `DeliveryReceipt.Base` — a nullable `tenant`
  column for a host that keeps receipts in one schema and still wants to know
  which tenant each was for (BACKLOG 10). `Notification.Base` and
  `Preference.Base` have had the column since 0.9.0; this is the receipt's.
- **`config :ash_dispatch, job_args: :minimal`** — the send job carries ids,
  not the rendered message, and the worker reads the message from the receipt
  (the shape a sensitive event has had since 0.8.7). **The default when
  receipts are per tenant**, because `oban_jobs` is one table in the public
  schema and the args would otherwise be the one place a tenant's letter leaves
  its own. `:full`, today's shape, stays the default for everyone else: that
  default cannot change inside 0.9.x.
- **`:tenant` on the functions a host calls** — `NotificationLoader.load_recent/2`,
  `unread_count/1`, `mark_as_read/2`, `CounterLoader.load_counters_for_user/2`,
  `Preview.render/3`, `WebhookHandlers.Resend.process_webhook/2`. For a
  per-tenant resource it is the schema; for one in the public schema it is the
  `tenant` column, which is what it has always meant. Which one is the
  resource's business, so a host passes it once either way.
- **`config :ash_dispatch, webhook_tenant_tag: true`** — an
  `X-AshDispatch-Tenant` header on outgoing mail, read back out of a provider's
  webhook payload. Off by default and only worth switching on behind
  `Resend.verify/3`: without a verified signature the tag is a value a stranger
  chose. A per-tenant webhook endpoint
  (`process_webhook(params, tenant: ...)`) needs none of it and is the better
  answer.

### Fixed

- **`ScrubSensitiveContent` reached no tenant schema at all.** Its query is raw
  Ecto against a table *name*, so without a prefix every run read the repo's
  default schema: for a host with per-tenant receipts the scrub found nothing,
  reported success, and left one-time tokens and reset links in the tenant
  schemas for good. It now scrubs with a prefix, once per tenant. (Flagged in
  the 0.9.4 design; the test for it fails without the fix.)
- **The `skip_if_read` policy asked the wrong schema.** `SendEmail` reads the
  in-app notification a letter is linked to; without a tenant that is either
  nothing or another tenant's reading.

### Changed

- **A dispatch with no tenant into per-tenant receipts is refused**, once per
  channel, naming the two ways to give it one. Not a fallback to `public`: a
  receipt in the wrong schema is worse than no receipt, because it looks like
  one. Only reachable by opting in.
- **A tenant that comes back from storage or from outside is checked.** An Oban
  job naming a tenant the host does not recognise is cancelled before any
  query, as is one whose schema does not exist — neither will fix itself on the
  second attempt. A job for tenant A edited to say tenant B finds nothing: the
  receipt id exists in one schema only. For a host without tenants a missing
  table is still a deploy that went wrong, and Oban still retries it.
- **The scheduled workers fan out instead of working.** With per-tenant
  receipts the crontab entry reads the host's tenants and enqueues one job per
  tenant, so a tenant whose pass fails fails its own job while the others run,
  and the work spreads across the queue. The crontab entry itself does not
  change. With no `:tenants` configured the workers say so once per VM rather
  than reporting success every five minutes.
- **One module decides whether a tenant is mentioned to Ash at all**
  (`AshDispatch.Tenancy`), and it asks the resource, never the presence of a
  tenant: Ash tolerates a tenant on a resource without multitenancy, and a
  library should not rely on being ignored. *Upgrade:* nothing — `opts/2`
  answers `[]` for every resource a host had before this release, which is what
  makes the whole of this additive.

## [0.9.3] - 2026-11-12

### Added

- **One delivery mode for every transport.** `skip_email_delivery` held back
  email and nothing else: a staging host with it switched on still sent the
  text messages, posted the webhooks and pushed to the browsers. New setting
  `config :ash_dispatch, delivery_mode:`, read by email, SMS, push, in-app and
  webhook (and by `:slack` and `:discord`, which travel the same worker):

  - `:live` — send. **The default**, so a host that sets nothing sees no change.
  - `:blocked` — never send. The receipt is `:skipped` and records that it was
    held back, and why.
  - `:dry_run` — render, create the receipt, enqueue the job, run the worker,
    and send nothing. The receipt holds the letter that would have gone out.
  - `{:allow_list, ["ops@example.com", "@example.test", "+4670"]}` — only these
    recipients are really sent to; everyone else is treated as blocked. An
    entry matches an exact address, a domain, a phone prefix, an explicit
    prefix (`"team-*"`) or `"*"`. A recipient it cannot read never matches.

  Per transport with a keyword list, `:default` for the rest:

  ```elixir
  config :ash_dispatch,
    delivery_mode: [
      default: :blocked,
      email: {:allow_list, ["@example.test"]},
      in_app: :live
    ]
  ```

  The mode is read at the moment of sending — in the send workers, and
  immediately before the write for the transports that deliver synchronously —
  so a held-back delivery still has its receipt and its job, which is what
  makes `:dry_run` worth running. `:broadcast` and `:oban` are not covered:
  they reach a topic and a queue in the same system, not a person, and have no
  receipt to record a hold on. The reasons (`"delivery_blocked"`,
  `"delivery_dry_run"`, `"delivery_not_allowed"`, see
  `AshDispatch.DeliveryMode.reason/1`) are stable, so they can be counted.
  *Upgrade:* nothing.
- **A check for whether a recipient may be reached at all**, which a mandatory
  event does not override. `metadata: [user_configurable: false]` walks past the
  preference check on purpose — a password reset is not a marketing choice — but
  that override was total: a closed account, a barred user or an address that
  was never verified still got the letter, because nothing in the library had
  ever been told that some recipients must not be reached whatever the message
  is.

  ```elixir
  config :ash_dispatch, eligible_recipient: MyApp.Notifications.Eligibility
  ```

  A module implementing `AshDispatch.EligibleRecipient` (or `{module,
  function}`, `{module, function, args}`, or a two-argument function). It is
  asked **when the recipients are resolved** and **again at the moment of
  sending**: a delivery can wait in a queue for hours — `delay:`, a retry, a
  stranded job rescued later — and the answer may have changed while it waited.
  An ineligible recipient gets a `:skipped` receipt carrying
  `"recipient_ineligible"` (with the host's own reason appended), never a silent
  drop: the receipt holds the letter that was written for them and says why it
  was held back. A check that raises, cannot be called or answers something
  other than `true` / `:ok` / `{:ok, true}` holds the delivery back and says so
  in the log — the question is whether a person may be contacted, and a host
  that cannot answer it has not said yes. `:broadcast` and `:oban` have no
  receipt to record a verdict on, so an ineligible recipient is simply not
  dispatched to and the log line is the record. *Upgrade:* nothing — without the
  setting nothing is asked.
- **A gate on the event: does it go out at all?** `should_send?/2` answered
  that with a boolean and left nothing behind — a channel it refused was
  dropped silently, and afterwards nobody could tell whether the event had been
  skipped or had never fired. A gate is the same decision with a record and a
  reason:

  ```elixir
  event :reminder,
    trigger_on: :manual,
    gate: {MyApp.Bookings, :still_booked?},
    channels: [
      [transport: :email, audience: :user, time: {:in, 86_400}],
      [transport: :in_app, audience: :user]
    ]
  ```

  `{module, function}`, `{module, function, extra_args}` or a one-argument
  function, called with an `AshDispatch.Gate.Info` struct; an event module may
  implement `c:AshDispatch.Event.gate/1` instead, and the DSL option wins over
  it. Evaluated at dispatch, once per channel, and **again at the moment of
  sending** — which is what makes it work for a reminder queued for tomorrow
  morning and a booking cancelled tonight. When it closes, a `:skipped` receipt
  carrying `"event_gate_closed"` (with the gate's own reason appended) exists
  for **every channel that would have been used**. Only `true` and `:ok` let the
  event out; a gate that raises, cannot be called or answers something else
  closes, logs an error and still leaves the records. A gate decides delivery,
  not side effects: `generate_send_variables/2` has already run when it is
  asked. *Upgrade:* nothing — an event without a gate is never asked. One thing
  to check: the callback is found with `function_exported?(module, :gate, 1)`,
  so an event module that happens to define a `gate/1` of its own now gates its
  event. Rename it, or have it return `true`.
- **A backend may answer that it did not send.** `{:skip, reason}` (or
  `{:skipped, reason}`) from an email or SMS backend leaves the receipt
  `:skipped` with the reason — a third outcome next to `:sent` and `:failed`,
  for an address on a provider's suppression list or a rule of the host's own.
  Before, such a backend had to choose between reporting a send that never
  happened and a failure that would be retried five times.

### Added (installer)

- **`mix ash_dispatch.install` writes the Oban configuration it used to
  print.** Four releases printed "give Oban these queues and these two
  scheduled workers" in a closing notice and left it at that (BACKLOG 1); a
  host that missed the notice never retried a failed delivery and never
  emptied a sensitive body, silently, which is the whole problem with a
  notice. The installer now writes `queues: [default: 10, emails: 10, sms: 5,
  webhooks: 5]` and a `Oban.Plugins.Cron` entry for
  `RetryFailedDeliveries` and `ScrubSensitiveContent`.

  It adds only what is missing. A queue size the host chose is kept; a cron
  schedule the host moved for one of our workers is kept and not duplicated
  (entries are compared by worker, not by schedule); an existing Cron plugin
  gets the missing entries, and a plugins list without one gets ours beside
  the host's. A plugins list shaped in a way the installer does not recognise
  is left untouched, and the notice still says what is needed.
- **A Preference resource**, `MyApp.Notifications.Preference`, built on
  `AshDispatch.Resources.Preference.Base`, listed in the Notifications domain
  and wired up (`preference_resource:`, `user_preference:
  AshDispatch.UserPreference.Resource`). A new install gets working
  preferences instead of a checker pointed at a table nobody created. It needs
  PostgreSQL 15 (`NULLS NOT DISTINCT`), which the closing notice says.
- **`config :ash_dispatch, retry_queue:`** — the queue
  `AshDispatch.Workers.RetryFailedDeliveries` runs in, read at runtime.
  **Still `:default`**: moving it to `:emails` would stop the retries of a host
  whose Oban has no `:emails` entry for it, without notice, so that waits for
  0.10.0. A `queue:` in the cron entry wins over it.

### Fixed (installer)

- **The installer can be run twice.** Every module it generates went through
  `Igniter.Project.Module.create_module/3`, which fails the run when the file
  is already there, so a second run stopped on "File already exists" before it
  did anything — and a host that wanted to re-run it after adding a repo or a
  user resource could not. A module that exists is now left alone, the inbox
  route is added only when the router does not already have it, and every
  config write was already additive. `mix ash_dispatch.install` twice over is
  a no-op.

### Changed

- **`skip_email_delivery` is now read in one place**, as
  `delivery_mode: [email: :blocked]`. It keeps the reason it has always written
  on the receipt (`"email delivery disabled (dev mode)"`), it still covers
  email only, and it beats a *global* `delivery_mode` — a host that had it
  switched on does not start mailing people by setting `delivery_mode: :live`.
  An explicit `delivery_mode: [email: ...]` beats it. *Upgrade:* nothing.
- **One place decides whether a delivery goes out**, `AshDispatch.Delivery`,
  called by the three send workers and — for the delivery mode alone — by the
  two transports that deliver synchronously. The gate, the eligibility check
  and the mode are asked in that order, so a receipt held back says why in
  terms of the message and the person first, and only then in terms of the
  host. A test pins that every send point asks.

### Not in this release

- **The tenant through the whole flow.** Every read the library makes is still
  made without a tenant: a host with `multitenancy strategy :context` and a
  schema per tenant writes its receipts into `public`, and
  `ScrubSensitiveContent` never reaches a tenant schema at all. Designed, with
  the work plan and all 86 reads that have no tenant today, in
  `docs/design/0.9.4-tenancy.md`. It is a patch's worth of work and it needs
  per-tenant test fixtures the suite does not have yet.
- The receipt's own `tenant` column (BACKLOG 10) is part of that design, not of
  this release: it is a new column, so it waits for the release that has a
  reason to ask hosts for a migration.

## [0.9.2] - 2026-11-12

### Changed

- **Recipients are masked in the log, and subjects are no longer logged.** The
  Swoosh backend wrote the full address and the subject line at info on every
  send; the dispatcher, the in-app transport and the workers wrote recipients
  and provider errors that quote the address back; the Resend handler wrote a
  whole webhook payload when it could not read one. A recipient is now written
  as `a***@example.com` or `***4567`, errors have addresses masked inside them,
  and a payload is logged by its shape only. New setting
  `config :ash_dispatch, log_recipients: :redacted | :none | :full`; `:full`
  restores the old lines for local development. Search the log by receipt id,
  which every delivery line carries. See `AshDispatch.Log`.

### Removed

- `priv/native/cl44_nif.so`, a compiled binary that was committed by mistake.
  Nothing loaded it and it was never part of the Hex package, but it came
  along with a git dependency.

### Fixed

- The installer asked for `oban ~> 2.0`; the library needs `~> 2.12`.
- The installer's closing notice now shows the Oban queues and the two
  scheduled workers to add. They were left out, and a host without them never
  retries a failed delivery and never empties a sensitive body - silently.
  The installer still does not write this configuration itself.
- The documentation's module groups listed three modules that do not exist.
- The changelog called published versions "Unreleased".

### Fixed (delivery)

- **An email whose job was interrupted is sent when the job runs again.** The
  worker marks the receipt `:sending` before it calls the backend. If the job
  then stopped without a result - the node went down, or the job was killed
  and Oban's lifeline put it back - the next run found the receipt in
  `:sending`, could not move it to `:sending` again, read that as "another job
  has this" and completed successfully. Nothing was sent, no error was logged
  above info, and the receipt stayed in `:sending` for good. The worker now
  looks at the job's attempt: a receipt in `:sending` on a second or later
  attempt is this job's own unfinished work, and is sent. On a first attempt it
  still belongs to another job and is left alone. No resource or migration
  changes. An email can now be sent twice if the earlier attempt reached the
  provider but died before recording it; that is the price of not losing it.

## [0.9.1] - 2026-11-06

The release of 0.9.0. The library code is unchanged from 0.9.0, which never
reached Hex: its publish run stopped on two tests that failed depending on
timing. Read the 0.9.0 entry below for what the release contains.

### Fixed (test suite)

- **ETS tables are emptied for real between tests.** `Ash.DataLayer.Ets.stop/1`
  ends the table's owner with `Process.exit/2` and returns before the owner
  is gone. A test that wrote in that gap wrote into the old table, which
  was deleted a moment later: a tenant's preference row that the dispatch
  never read, a notification the unread count never saw. The new test helper
  `AshDispatch.Test.Ets.stop/1` waits for the owner to exit (a monitor, not
  a sleep), and the inbox, meeting and actor/tenant fixtures use it.

## [0.9.0] - never published; released as 0.9.1

A notification centre and per-person preferences in the library: who acted,
what a person wants, what a tenant defaults to, what can never be switched
off — and an unread count that stays live in a LiveView. Built on 0.8.8;
read its entry first.

### Requires Elixir 1.17

**`mix.exs` now says `elixir: "~> 1.17"`** (it said `~> 1.15`). Ash 3.33
already needed 1.17 (`Duration`), so a default install could not run on less;
the declared floor now says so. An app on Elixir 1.15 or 1.16 stays on 0.8.x.
CI's floor job runs on 1.17.

### Upgrading: what to do

1. **Generate and run migrations.** `DeliveryReceipt.Base` gains `actor_id`;
   `Notification.Base` gains `category`, `tenant`, `seen_at` and
   `archived_at`. Ash reads every attribute a resource declares, so a
   database without the columns fails on read:

       mix ash.codegen ash_dispatch_0_9_0
       mix ecto.migrate

   All five columns are nullable; existing rows need no backfill. A receipt
   resource of your own without `actor_id` keeps working, without it.
2. **Manual sends that pass `:actor` now leave the actor out of
   `exclude_actor: true` channels.** `exclude_actor_on_manual_dispatch`
   (opt-in in 0.8.8) defaults to `true`. To keep 0.8.x's behaviour:

       config :ash_dispatch, exclude_actor_on_manual_dispatch: false

   `context.user` does not change: on a manual event it is still the user
   found in `data`; the actor is `context.actor`.
3. **A custom preference checker is no longer asked about mandatory
   events** (`metadata: [user_configurable: false]`, or `user_configurable?
   false` in an event module): they are delivered, whatever the checker
   would say. Its opts also carry `:event_default`. Move a mandatory event
   you do want gated to `user_configurable: true`.
4. **`Preference.Base` needs Postgres 15** (`NULLS NOT DISTINCT` on its
   scope identity). Only if you use it.
5. **`phoenix_live_view` is a new optional dependency** (`~> 1.0`), for
   `AshDispatch.Phoenix.LiveView`. Nothing changes for an app without it.
6. **Under `authorize :when_requested`** in your domain, `Notification.Base`'s
   per-user policies only run when a call asks for authorization — as
   before, but now a bell and a settings screen read through them too.

### Added

- **`actor_id` on every receipt**: `context.actor`'s id (the action's actor,
  or `Dispatcher.dispatch/4`'s `:actor`), else the user found in `data`.
- **In-app notifications are filed under the event's `category` and the
  dispatch's tenant** (`AshDispatch.Context.tenant_key/1`: a binary as it
  is, a record by its `:id`).
- **Mandatory events.** `metadata: [user_configurable: false]` is never
  gated, by any checker. `AshDispatch.UserPreference.user_configurable?/1`.
- **An event's own default**, `metadata: [preference_default: false]` or per
  transport (`[email: false]`), handed to the checker as `:event_default`.
  `AshDispatch.UserPreference.event_default/2`.
- **`AshDispatch.Resources.Preference.Base`** — rows per (tenant, person or
  the tenant's default, event or category, transport) with `enabled`. The
  person beats the tenant, the tenant beats the event's default; an event
  row beats a category row. Policies: a person reads their own rows and the
  defaults and writes their own; a tenant default needs
  `permission: :manage_notification_preferences`, and the permission checker
  gets `tenant:` the row's tenant so it can check the actor manages it; with
  an Ash tenant on the action, the row's tenant must be that tenant.
- **`AshDispatch.UserPreference.Resource`** — the standard checker for it.
  One query per dispatch: the dispatcher hands a channel's recipients to the
  new optional `c:AshDispatch.UserPreference.prefetch/2` callback, and what
  it reads is kept for the rest of the dispatch
  (`with_dispatch_scope/1`, `scope_get/1`, `scope_put/2`).
- **For a settings screen:** `Resource.configurable_events/1`, `settings/3`
  (every event × transport with the answer for one person, its source and
  the tenant default "reset" returns to), `put/3` and `clear/2`.
  `settings/3` reads without authorization: pass it the signed-in user's id,
  never one from the request.
- **`Notification.Base`:** `category`, `tenant`, `seen_at`, `archived_at`;
  actions `:unread` (read), `:unread_count` (the actor's count),
  `:mark_as_seen`, `:mark_all_as_seen`, `:archive`, `:unarchive`.
  `mark_as_read` also sets `seen_at`. Reading broadcasts
  `"notifications_read"` on the user's topic. A tenant filter (`:unread`,
  `:unread_count`, `mark_all_*`) includes notifications without a tenant:
  they belong to the person, so pre-0.9.0 rows stay in every inbox.
- **`AshDispatch.Phoenix.LiveView`** — `on_mount` hook that subscribes to the
  user's topic and keeps the unread count in an assign, with a `handle_info`
  hook and an optional `handle_notification/3` in the LiveView; helpers
  `mark_all_as_read/1` (within the hook's tenant) and `refresh/1`. Guide:
  [LiveView Notifications](liveview.html).
- `NotificationLoader.unread_count/1`, `broadcast_read/1`, and `:tenant` on
  `mark_all_as_read/2`; `config :ash_dispatch, preference_resource:`.
- `Notification.Base` and `Preference.Base` take `data_layer:` —
  `Ash.DataLayer.Ets` for an app's own tests.

### Changed

- **`exclude_actor_on_manual_dispatch` defaults to `true`** (see above).
- **`mark_all_as_read`'s `user_id` is optional**: without it the action
  marks the actor's own feed, and with it only the actor's. The actor is
  carried into the bulk update.
- **The `unread_notifications` counter counts what `:unread` counts**: an
  archived notification is not unread. It also fires on `:archive` and
  `:unarchive`.

### Not in this release

- The dependency round BACKLOG 9 meant the Elixir floor to travel with: the
  floor is raised, the library update pass is still open.

## [0.8.8] - 2026-11-06

Fixes and opt-in additions only: no migration, and an app on `~> 0.8.7`
reaches the same people as before unless it turns something on.

### Fixed

- **`NotificationLoader.mark_all_as_read/2` passes `:actor` on.** It dropped
  its options, so the action ran without an actor and the notification
  resource's policy (`user_id` must be the actor's) refused every call.
  `:actor` and `:authorize?` reach the action now. *Upgrade:* nothing — a
  call that passed `actor:` and got `{:error, %Ash.Error.Forbidden{}}` now
  marks the notifications as read. The return value is `{:ok, %{success: true}}`
  (the docs said `marked_count`; the action never returned one).
- **An audience in the atom shorthand in `recipient_fields`** (`audiences:
  [user: :email]`) no longer raises in the field lookup.

### Added

- **`recipient_fields` `id:`** — where a map recipient keeps its user. A
  receipt's `user_id` was always the recipient's `:id`, so a contact map
  `%{user_id: ..., email: ...}` from a resolver got a receipt without a user:
  no preference gate, no in-app notification, never matched by
  `exclude_actor`. Name the key generically, per transport, per audience, or
  per audience and transport:

  ```elixir
  config :ash_dispatch,
    recipient_fields: [
      email: [identifier: :email],
      audiences: [bookers: [id: :user_id]]
    ]
  ```

  Without `id:` nothing changes. `RecipientExtractor.extract_user_id/4` is
  public. *Upgrade:* add `id:` where your recipients are maps with the user
  under another key.
- **The preference checker gets `:tenant` and `:recipient`** in its opts,
  next to `:category`, `:audience` and `:event_id`. `:tenant` is the action's
  tenant for an action-triggered event and `Dispatcher.dispatch/4`'s new
  `:tenant` for a manual one (`nil` without); `:recipient` is the resolved
  recipient of the receipt being checked. `allows_user?/4` passes both on
  when given. *Upgrade:* nothing; a checker that keeps preferences per
  organisation can read `opts[:tenant]`.
- **`Dispatcher.dispatch/4` takes `:tenant`** (`context.tenant`), and the
  ManualTrigger's `:trigger` action passes its own tenant. An action-triggered
  event's `context.tenant` is the action's tenant.
- **`Dispatcher.dispatch/4`'s `:actor` is kept as `context.actor`** (it only
  named who asked for an override before), and the ManualTrigger's actor
  with it. An action-triggered event's `context.actor` is the action's
  actor. `context.user` does not change: on a manual event it is still the
  user found in `data`.
- **`config :ash_dispatch, exclude_actor_on_manual_dispatch: true`** makes a
  channel's `exclude_actor: true` leave out a manual dispatch's `:actor`
  too. **Off by default in 0.8.x**: an app that already passes `actor:`
  reaches the same people after upgrading. **0.9.0 turns it on by default.**
  *Upgrade:* turn it on if you want 0.9.0's behaviour now, and pass `actor:`
  on manual dispatches whose channels say `exclude_actor: true`.

### Not in this release

- The actor's id on the receipt needs a new `actor_id` column, so it comes
  with 0.9.0 and its migration.

## [0.8.7] - 2026-11-01

### Security

- **A sensitive event's bodies no longer sit in `oban_jobs`.** The email
  transport copied the rendered `html_body` and `text_body` into the
  `SendEmail` job's args for every event, so a reset link or one-time token
  stayed in `oban_jobs` until the Pruner removed the completed job — out of
  reach of `ScrubSensitiveContent`. For an event declaring
  `metadata: [sensitive_content: true]` the args now carry only `receipt_id`,
  `event_id` and `attachments`; the worker reads the envelope and the bodies
  from the receipt at send time, the path every retry already took.
  Attachments stay in the args — a retry reads them back from the original
  job — so an event must not put a live secret in an attachment.
- **The worker fails closed for a sensitive event with no body left.** If the
  receipt holds no body, or the scrub's marker, nothing reaches the backend:
  the receipt goes to `:failed_permanent` and the job is cancelled.
- **`SendSMS` fails closed the same way**, for a sensitive event with no text left.
- **`ScrubSensitiveContent` takes terminal receipts** (`:sent`, `:skipped`,
  `:failed_permanent`) after `:scrub_after_hours`, so a letter that can still be
  sent keeps its body. Any other status is scrubbed at the new cap
  `:scrub_stranded_after_hours` (default 168): a receipt stranded in `:sending`
  or `:pending` must not keep a live secret forever.
- **The scrub also removes an SMS's text** (`message`, `body`) from `content`,
  which no earlier version reached.
- **A warning when `sensitive_content` cannot be read**: an event the registry
  does not find gets the full job args, and now says so.

### Changed

- **Requires Oban `~> 2.12`**, for `{:cancel, reason}`.
- **Publishing needs a green CI run on main**, with the Postgres tests. The
  publish workflow starts from CI instead of from the push.
- **`ScrubSensitiveContent` empties the copy in `content` too.** The receipt
  stores the rendered bodies twice, in `body_text`/`body_html` and under
  `html_body`/`text_body` in `content`; the scrub only blanked the first.
  Both are emptied now, and receipts scrubbed by an earlier version are
  picked up again while their content still holds a body.

## [0.8.6] - 2026-10-27

### Added

- **`AshDispatch.Preview`** — render any event exactly as it would be sent,
  without sending it.
  - `events/0`: the catalogue, one row per event × channel (transport,
    audience, variant) with the event's metadata (resource, trigger,
    category, `sensitive?`, locales).
  - `render/3`: from `:sample` data, `{:record, id}` or a data map, with
    `seed:`, `transport:`, `audience:`, `variant:`, `locale:`,
    `recipient_email:` and `actor:`. Returns `AshDispatch.Preview.Rendered`
    structs carrying the envelope the email backend would receive — `to`,
    `from`, `reply_to`, `subject`, `html_body`, `text_body`, `attachments`,
    `headers`.
  - **No second renderer.** It opens the event through the send path's own
    functions (`Dispatcher.prepare/3`, or the notifier's preparation for an
    action-triggered event), resolves the recipient like the dispatcher,
    renders through the function that builds the receipt, and builds the
    envelope with the email transport's job args and the `SendEmail` worker's
    backend params. A parity test sends letters for real (both the notifier
    and `dispatch/3`) and compares them with their previews field by field.
  - **No side effects.** A preview never calls `generate_send_variables/2`
    (where events mint tokens and write rows), creates no receipt or job, and
    with `read_records?: false` / `resolve_recipients?: false` reads nothing
    from the database at all — which is how `EmailEvent` uses it.
  - `AshDispatch.preview/3`, the `EmailEvent` resource and the ManualTrigger
    `:preview` action now render through it.
- **`sample_data/1`** on events, called with `seed: integer`; the default
  calls `sample_data/0`. A `:sample` preview seeds the process's `:rand` with
  the seed (and restores it afterwards), so the same seed gives the same
  letter whichever callback the event defines.
- **`AshDispatch.Test.assert_all_render/1`** and **`render_all/1`**: render
  every row of the catalogue from sample data, once per seed, and fail on a
  letter that could not be rendered, an email with an empty subject or no
  body, or output still containing `<%`, `{@`, `#{`, a HEEx block expression
  or `TODO` (plus `forbid:` markers of your own). Returns the number of
  letters rendered, so an app's "every mail renders" test is one line with an
  exact count. `problems_for/2` runs the same checks on a single letter.
- **Strict templates** — `config :ash_dispatch, strict_templates: true`
  refuses `.heex` templates with `{if`, `{for`, `{case` (and `unless`,
  `cond`, `with`) or `#{` in body position: the `:ash_dispatch` compiler fails
  the build with the file and line of each, and `TemplateResolver` refuses to
  render one (`AshDispatch.TemplateError`, raised by the send path). Off by
  default. See `AshDispatch.StrictTemplates`.
- **`headers/2`** on events: extra email headers such as `X-Entity-Ref-ID`.
  Stored in the receipt (so a retry keeps them), passed to the backend as
  `:headers` and added by `AshDispatch.EmailBackend.Swoosh`. Names the
  envelope already sets (`To`, `From`, `Subject`, `Reply-To`, …), values that
  are neither strings nor integers, and values with line breaks are dropped
  with a warning.
- **`Dispatcher.dispatch/4`** with options for manual sends: `:channels`,
  `:recipient_email`, `:skip_preferences`, `:actor`.
- A guide, **Previews and testing**.

### Fixed

- **ManualTrigger `:trigger` honours `recipient_email`, `audience`,
  `transport` and `skip_preferences`** (BACKLOG #2). They were packed into the
  template variables and read by nothing, so "send a test to myself" mailed
  the real recipient. A recipient override now dispatches only email
  channels, each rendered for its first resolved recipient and sent to the
  override as one receipt without a `user_id`; `content.manual_override`
  records the address, the recipient it replaced and the actor.
  `skip_preferences` bypasses both opt-out gates and is recorded the same
  way.
- **The trigger no longer generates the send variables twice.** An event
  that minted a token in `generate_send_variables/2` minted two and mailed
  the second.
- **A cron retry is enqueued once** (BACKLOG #1). `RetryFailedDeliveries` ran
  the `:retry` action — which enqueues a job — and then enqueued another; an
  in-app retry, which delivers inline, was delivered twice. `SendEmail` and
  `SendSMS` uniqueness now also covers `:retryable`, so a cron retry no longer
  lands beside the job Oban's backoff is about to run — instead that waiting
  job is made available at once, so "send now" sends now.
- **A retried email keeps its sender.** Without content args the worker read
  the sender from the receipt with an atom key, which a JSONB-stored receipt
  does not have, and sent from the default address.
- **The legacy `AshDispatch.Resources.ManualTrigger`'s `:trigger`** no longer
  raises (`FunctionClauseError`); it and `:preview` run through the same
  helpers as `.Base`.

### Changed

- **Previews show what is sent.** The ManualTrigger/`AshDispatch.preview/3`
  maps keep their keys, but their content now comes from the send path:
  `recipient` is the identifier the receipt is addressed to (the
  `Name <email>` formatting was preview-only), bodies are trimmed as the
  receipt stores them, and `EmailEvent`'s `preview_html`/`preview_text` come
  from the same render.
- `AshDispatch.Notifier.DispatchHandler` and `AshDispatch.Dispatcher` expose
  their preparation (`prepare/4`, `prepare/3`, `recipients_for/3`,
  `build_receipt/4`) as `@doc false` functions — the seam the preview renders
  through, not public API.

## [0.8.5] - 2026-09-23

### Documentation

- **Four guides that existed but were never published.** `architecture.md`,
  `delivery-receipts.md`, `localization.md` and `priority.md` sit in
  `lib/documentation/topics/` and are linked from other pages, but were
  missing from `extras` in `mix.exs` — so every link to them was dead on
  HexDocs. They are published now.
- **References to things that do not exist.** `AshDispatch.Naming` and the
  broadcast transport both described a per-event `wire_event_name/0`
  callback on `AshDispatch.Event`; there is no such callback and never was.
  The text now says what actually happens: every transport routes through
  `AshDispatch.Naming.wire_event_name/1`. Stale references to private and
  renamed functions are corrected too, which takes `mix docs` from 15
  warnings to 2 — both of them about a module hidden in ash_typescript's own
  docs.

### Internal

Not part of the published package (`config/` and `mix.lock` are not shipped),
but worth recording:

- **Dependencies refreshed.** ash 3.9.0 → 3.33.9, ash_postgres 2.6 → 2.13,
  spark 2.3 → 2.7, ash_typescript 0.7 → 0.18, igniter 0.7 → 0.8, plus oban,
  swoosh, req and the rest. This clears 16 packages carrying published
  advisories, several rated HIGH — and, more to the point, the suite had been
  running against Ash 3.9 while `mix deps.get` in a fresh app resolves 3.33.
  All 576 tests pass on both Elixir 1.17 and 1.18.
- **`config :ash, :default_string_length_count`** is now set (`:codepoints`)
  for this project's own builds: Ash 3.33 makes every application choose.
  Consuming apps are unaffected and make their own choice — Ash skips the
  check for resources compiled as a dependency.
- **CI moves to Elixir 1.18 / OTP 27**, because igniter now pulls in `ex_ast`,
  which requires 1.18. `compile-without-optional-deps` runs on 1.17 instead,
  so the library is still held to a floor rather than to whatever is newest.
  It cannot be 1.15: Ash 3.33 uses `Duration` and does not compile there,
  although it declares `~> 1.11`. `mix.exs` keeps `~> 1.15`, which stays true
  for an app that pins an older Ash — ash_dispatch's own code compiles there.

## [0.8.4] - 2026-09-22

### Fixed

- **`mix igniter.install ash_dispatch` generates a project that compiles.** It
  never had:
  - every module name came out as `MyApp..Notifications…` —
    `module_name(igniter, "")` concatenates an empty segment;
  - every module was nested inside a second copy of itself —
    `create_module/3` wraps its contents in `defmodule` and was handed a whole
    `defmodule`, leaving the outer module empty;
  - the resources used `AshDispatch.Notification` and
    `AshDispatch.DeliveryReceipt`, which have never existed.

  The resources are now built on `Notification.Base` and
  `DeliveryReceipt.Base` with the project's repo and user resource, as the
  integration guide does. The installer also sets `:repo`,
  `:notification_resource` and `:delivery_receipt_resource`, which the
  runtime reads and which it never configured.

  Further down the same path:
  - The generated `UserChannel` defined `broadcast_counter/3` and pushed
    `"counter_update"`. `CounterHandler` calls the configured function with
    four arguments and the SDK listens for `"counter_updated"`, so no counter
    update ever arrived. It is now the reference channel from the Phoenix
    guide.
  - Without a user resource it generated a `RecipientResolver` matching on a
    struct that doesn't exist. It now skips the resolver and says how to add
    one.
  - `--no-typescript` now also keeps the generated resources plain. Without
    it, they get `AshTypescript.Resource` and a type name only when
    ash_typescript is a dependency.

- **`use AshDispatch.Setup` works.** It never compiled: the resource body was
  spliced into the domain module instead of being passed to `Module.create/3`
  as quoted code, so `use Ash.Domain` right after it failed with "can be
  called only one time". It is now a thin wrapper over `DeliveryReceipt.Base`
  rather than a hand-kept copy that had drifted from it (no `:slack`, no
  `send_now`, no `get_by_provider_id`, …), and aliases in its options resolve.

- **swoosh is optional in fact, not only in `mix.exs`.**
  `AshDispatch.EmailBackend.Swoosh` did `import Swoosh.Email`, which needs the
  module at compile time, so an app without swoosh could not compile
  ash_dispatch. Without it the backend now returns
  `{:error, "swoosh is missing — …"}`, the way the Elks backend reports a
  missing req. The webhook worker does the same for req instead of raising
  `UndefinedFunctionError`.

- **No compile warnings for absent optional dependencies.** An app without
  swoosh, req, plug_crypto or phoenix_pubsub got 13 "is undefined" warnings
  from ash_dispatch. plug_crypto and phoenix_pubsub were also called without
  being declared; they are now `optional: true` dependencies.

### Changed

- `AshDispatch.Transports.Webhook`'s `hemlighet/1` is now `secret/1`. The Swedish
  name remains as a deprecated alias.
- The Swedish that 0.8.3's translation missed — written without å/ä/ö, so a
  search for those letters could not find it — is now English too: private
  helpers (`leverera`), test names, comments and fixtures.

### CI

Two new jobs. `compile-without-optional-deps` (formerly
`compile-without-ash-typescript`) builds ash_dispatch as an app's only
dependency and fails on any warning. `installer` runs
`mix ash_dispatch.install` in a bare Ash app, adds a domain that uses
`AshDispatch.Setup`, and requires the result to compile without warnings and
to produce migrations.

### Compatibility

`use AshDispatch.Setup` now requires `:notification_resource`. Since it never
compiled before, nothing that worked breaks. Projects generated by an earlier
installer never compiled either; re-running the installer on a fresh branch
is simpler than repairing one.

## [0.8.3] - 2026-09-22

### Fixed

- **ash_dispatch compiles without `ash_typescript`** (#31). The dependency is
  declared `optional: true`, but `AshDispatch.Resources.EmailEvent` and
  `AshDispatch.Resources.ManualTrigger` named `AshTypescript.Resource`
  unconditionally — and they are compiled as part of the library itself. An
  app without ash_typescript therefore failed in `mix deps.compile`, on
  `undefined function typescript/1`, and the installer's `--no-typescript`
  could not help. It had been that way since the first version.

  The TypeScript half of both resources now lives in a Spark fragment
  (`…EmailEvent.Typescript`, `…ManualTrigger.Typescript`) that carries the
  extension and `type_name` when ash_typescript is present and is empty when
  it is not. `AshDispatch.Setup` picks its extension list on the same
  condition, evaluated in the consuming app.

  An app **with** ash_typescript sees no difference: the extensions and type
  names (`"EmailEvent"`, `"ManualTrigger"`) are unchanged, so existing
  `typescript_rpc` blocks keep working.

  A new CI job, `compile-without-ash-typescript`, builds the library as a
  dependency of an app without it, pinned to the library's own `mix.lock`.
  It fails on `main` before this change and passes after it.

### Note

If you add ash_typescript to an app later, run
`mix deps.compile ash_dispatch --force` once. Mix does not rebuild a
dependency when an optional dependency appears, so the fragments would
otherwise stay without the extension.

## [0.8.2] - 2026-09-21

### Added

- **SMS goes through the queue.** `:email` and `:webhook` enqueued an Oban job
  and marked the receipt `:scheduled`. `:sms` called the backend's `deliver/4`
  directly — synchronously, inside the `after_action` hook where dispatch
  happens, and therefore inside the action's transaction. A slow provider held
  that transaction open, and `time:` could not be used because there was no job
  to schedule.

  It now takes the same shape as email, with `AshDispatch.Workers.SendSMS`
  mirroring `SendEmail`: queue, `:scheduled`, and therefore `time: {:in, n}`
  and `{:at, dt}` for free. Requires an Oban queue named `:sms`.

  The consent gate arrived in 0.8.0 (`Preferences.with_consent`) and stays
  above the queue — a receipt the recipient opted out of should never become a
  job.

  An existing backend keeps working — it is simply called from the worker
  rather than from the transaction. **But** the job carries only the receipt
  id, so the context it receives is reconstructed from the receipt: `event_id`
  and `audience` are real, `data` and `variables` are empty. A backend that
  read `context.data` should read `receipt.content` instead, which was frozen
  at creation and survives a retry for exactly that reason.

- **`AshDispatch.SMSBackend.Elks`** — 46elks, packaged the way
  `EmailBackend.Swoosh` is, behind the already-optional `req` dependency.
  E.164 normalisation, a `dryrun` flag, and `:req_options` so it can be stubbed
  in tests. `400`, `401` and `403` are marked `:failed_permanent` immediately: a
  malformed number does not become valid after five retries, and while it sits
  as `:failed` it only delays telling the person who can fix it.

- **`AshDispatch.SMSBackend.Phone`** — E.164 from the ways people write phone
  numbers. Its own module with its own test table, because this is the function
  that decides whether a message reaches a person or goes quietly nowhere.

### Fixed

- **A failed SMS was never retried.** `Workers.RetryFailedDeliveries` and
  `Changes.EnqueueRetryJob` knew only `:email` and `:in_app`; everything else
  fell into a catch-all. The consequence was not that the receipt was left
  alone: `:retry` still ran, incremented `retry_count`, and the enqueue failed
  — back to `:failed`. Five cron passes and 75 minutes later it read
  `:failed_permanent`, without having been resent even once. `:retry`,
  `:reopen` and `:send_now` in admin refused it for the same reason, so there
  was no way back at all.

  Deliberately distinct from a transport that has no worker: `:broadcast` and
  `:oban` keep no receipts, and therefore have nothing to retry.

- **The map of what can be retried existed in two copies.** The same three
  branches in the cron and in the admin actions, so a transport could be
  retried by one and not the other. It now lives in
  `AshDispatch.Transport.Retry`, which answers which strategy a transport has.
  Result handling stays with the caller, because that genuinely differs: the
  cron wants to know the receipt is already fully handled, the action wants a
  job id to store.

### Note

`recipient_fields` must carry an `:sms` entry, or **every** recipient raises
`"No identifier field configured for sms transport"` — and the error does not
say where to look:

```elixir
config :ash_dispatch,
  recipient_fields: [
    sms: [identifier: :phone, name: [:display_name, :name]]
  ]
```

## [0.8.1] - 2026-09-20

### Added

- **`reply_to/2`** — an email can finally carry a `Reply-To` header.

  The sender (`from/2`) is the organisation: an address that often does not
  accept replies. But an email WRITTEN by a person — *"we're moving our
  meeting"*, *"here's your quote"* — invites an answer, and without a reply
  header that answer lands in `noreply@` and is read by nobody.

      def reply_to(context, %Channel{transport: :email}) do
        context.data.meeting.user.email
      end

      def reply_to(_context, _channel), do: nil

  The default is `nil`, i.e. exactly today's emails. Anything that is not a
  non-empty string is treated as `nil`, and a callback that raises does not
  bring the send down: an email without a reply header is cheaper than an
  email that never leaves.

  **Why it is carried in `receipt.content` and not only in the job's args.**
  `SendEmail.new_for_receipt/1` builds a retry — and every *send now* — from
  the RECEIPT, and carries no content args at all. A `reply_to` that lived
  only in the first job's args would therefore be lost on every retry,
  silently, and only on the retry. It is the same trap attachments already
  have special handling for (`maybe_put_original_attachments/2`); here it is
  solved by the value being in the receipt. A bonus: the field can be READ
  afterwards, so a consumer can measure that the reply path was actually set
  rather than assume it.

  Old queued jobs lack the key, get `nil`, and behave as before the upgrade.
  `AshDispatch.Workers.SendEmailTest` proves both directions.

  **Why it was needed.** One consumer had solved it with a proxy in front of
  the Swoosh backend that looked the sender up in the database by recipient
  plus subject, per email — a second state machine beside the library's, and
  one read per send. That is a symptom of a missing callback, not a design.

## [0.8.0] - 2026-09-14

### Added

- **`extra_content/2`** — a module may contribute content keys of its OWN.

  A transport's content is a closed list: `:in_app` carries a title, a body and
  a way onward, `:webhook` the same, `:email` its bodies. That is enough while
  the receiver is a notification list. It is not enough when the receiver is a
  surface that can render facts in two columns, several buttons and an icon —
  without this, every new key of that kind is a change to the library.

      def extra_content(context, %Channel{audience: :slack_channel}) do
        %{slack_icon: "contract", slack_fields: [%{label: "Amount", value: "13,995"}]}
      end

  The addition is merged **below** the transport's own keys: a module
  returning `%{message: ...}` does not overwrite `notification_message/2`. It
  is for what is missing, never for rewriting what is there. Anything that is
  not a map is ignored, and a callback that raises does not bring the dispatch
  down — a notification that never arrives costs more than a field that is
  missing.

### Fixed

- **`:webhook` could not carry a title or a way onward from a MODULE.**
  `build_module_content/5` had a branch per transport and `:webhook` fell
  through to the catch-all — `%{message: notification_message(...)}` and
  nothing else. `notification_title/2`, `action_url/2` and `action_label/2`
  were never called for that transport.

  `:in_app` has always carried all four. That `:webhook` did not was no
  declaration, it was that nobody had written the branch. (0.7.3 fixed the same
  class on the DSL side; this is the module side of the same gap.)

  Measured at a consumer: of six distinct channel posts in production, ONE
  carried a title and NONE carried a link.

  The guard `AshDispatch.Transports.WebhookModuleContentTest` checks both
  properties, mutation-tested: three mutations fail three tests.

## [0.7.3] - 2026-09-14

### Fixed

- **The `:webhook` transport could not carry a way onward.** The `:webhook`
  branch of `build_inline_content/4` read `title` and `message` (after 0.7.2)
  but never `action_url`/`action_label`. A declared

      content: [message: "...", action_url: "https://...", action_label: "Open the demo"]

  was therefore half decoration: the text arrived, the way there did not, and
  the sender had no way to notice except by reading what was delivered.
  `:in_app` and `:push` have always carried the keys; `:webhook` was the only
  transport with a receiver that can render a button and no ability to get a
  url to it.

  Reported by a consumer who described their Slack channel posts as *"dead
  notifications"* — the team learned something had happened but could not get
  there.

  `:discord`, `:slack` and `:sms` DELIBERATELY do not get the keys: their
  payloads have no button shape of their own, and a url without a surface that
  renders it is a key that only looks like it does something.

  The guard `AshDispatch.Transports.InlineContentTextTest` now checks both
  properties per branch — that the body is read, and that the way onward is
  read by the transports that can show it. Mutation-tested: removing the lines
  fails two tests.

## [0.7.2] - 2026-09-14

### Fixed

- **The `:webhook` transport dropped its declared body.** The `:webhook` branch
  of `build_inline_content/4` built only `payload` and `webhook_url`. It never
  read `content_config[:message]` — the only one of six body-carrying branches
  that did not.

  The bug was of the silent kind. An event WITH an event module falls back on
  the module's `notification_message/2`, whose generated default is
  `"You have a new notification"`. The merge order in `build_content/5` lets
  the module's value stand for every key inline content does not set, so a
  declared `content: [message: ...]` on a webhook channel became
  **decoration** — and the recipient got the placeholder, the right shape with
  the wrong content. Without a module, `message` would have been missing
  entirely and the receiver could have rejected the envelope; the event having
  a module therefore turned a hard failure into a valid string.

  Measured at a consumer before the fix: **41 of 41** delivered webhook
  receipts carried the placeholder, across nine declared channels. None of the
  written text had ever arrived, for as long as the channels had existed.

  The branch now carries `:message` and `:title` through `maybe_put/3`.

- **`:discord`, `:slack` and `:sms` could overwrite the module's body with
  `nil`.** The same class in the other direction: they set `message:` as an
  unconditional key, and `interpolate(nil, _)` returns `nil`. A channel that
  declared everything EXCEPT the body therefore erased the module's callback
  value. All three now use `maybe_put/3`, as `:in_app` and `:push` already did.

### Added

- `AshDispatch.Transports.InlineContentTextTest` — a guard requiring every
  body-carrying transport branch to read `content_config[:message]` and set it
  with `maybe_put`. The existing structural test only asked whether the branch
  EXISTED, and therefore saw a branch carrying the wrong content as a branch
  that worked.

## [0.7.1] - 2026-09-10

### Fixed

- **The orphaned-provider warning could go silently missing.** The latch that
  makes it log only once per VM was set **before** the condition was checked.
  The very first delivery in a node therefore decided forever whether the
  warning could ever appear: an app that set `:preference_provider` after that
  delivery — an umbrella booting in an unlucky order, a `runtime.exs`, a test
  suite — was latched into silence by a call that had nothing to warn about.

  A warning that can silently go missing is exactly the class of bug the
  warning exists to report. The condition is now checked first and the latch is
  set only when the warning actually logs. The cost is two ETS reads per
  delivery, which is less than the cost of being wrong about it.

## [0.7.0] - 2026-09-10

### Changed

- **Every transport that reaches a person now asks for consent.** Until now
  three of seven did: `:email`, `:in_app` and `:webhook`. `:slack`, `:discord`,
  `:sms` and `:push` delivered regardless of what the recipient had chosen.

  It looked like a gap rather than a decision, and it was of the silent kind: a
  person who turned a notification type off got it anyway — on another channel,
  without anything saying so. The preference was not broken, it was
  **partially** honoured, which is worse than not existing, because the person
  believes it applies.

  This is a BEHAVIOUR CHANGE for existing consumers, and therefore a minor bump
  rather than a patch: a `:slack` channel with a gated audience (`:user` by
  default) will now skip receipts it used to send. Set the audience to
  something ungated, or use `preference_gated_audiences`, if that is not what
  you want.

### Added

- **`AshDispatch.Transports.Preferences.with_consent/5` — the gate in ONE
  place.** The check is eight lines, and eight lines copied six times are six
  chances to drift apart. The copies had already started: `:in_app` logged the
  user id, `:webhook` logged the receipt id, and neither said which was
  intended.

  `:email`, `:in_app` and `:webhook` moved to the same function — not as
  tidying, but so that the reason on a skipped receipt is **one** value you can
  count. A dashboard filtering on opt-out should not miss a transport that
  spelled it differently. `Preferences.reason/0` is public for exactly that
  reason.

  The caveat, written down: this covers the transport gate's reason. The
  `SendEmail` worker still writes `"User opted out of this email category"`
  when its own provider path refuses (see below). Two reasons, two systems — a
  count has to know about both for now.

- `:oban` and `:broadcast` are deliberately outside the rule. They have no
  person to ask, and a consent gate there would imply a recipient that does not
  exist. A test guards that they stay outside, so the next reader sees it is a
  decision and not something forgotten.

### Added

- **`AshDispatch.UserPreference.LegacyProvider` — the bridge between the
  library's TWO preference systems.** This is the real finding in this release,
  and it only surfaced when the above was measured against a real consumer.

  The library has two preference systems that never met:

  | | read by | configured as |
  |---|---|---|
  | `AshDispatch.UserPreference` | every transport, via `allows_receipt?/4` | `:user_preference` |
  | `AshDispatch.Behaviours.PreferenceProvider` | the `SendEmail` worker and manual triggers | `:preference_provider` |

  An app that wired up **only** the second — and the guides pointed there for
  years — gets its rule honoured **on email and nowhere else**. Nothing said
  so. The rule looked configured, was configured, and silently covered one
  transport out of seven.

  That is the same class as the rest of this release, but worse: an app that
  has configured nothing at all at least knows it has no opt-out.

  The bridge lets the existing provider answer for all seven:

      config :ash_dispatch,
        preference_provider: MyApp.PreferenceProvider,
        user_preference: AshDispatch.UserPreference.LegacyProvider

  The semantics are copied from `SendEmail`'s private preference check —
  including that an `{:error, _}` from the provider **lets the message
  through**. A preference database that is down must not become a mute button:
  a notification that never arrives is invisible to everyone, including the
  recipient.

  Wiring it up is opt-in deliberately. Making the bridge the default would have
  silenced recipients in existing apps on a patch upgrade — precisely what
  makes this class of bug hard to find.

- **The library speaks up about the orphaned provider.** If
  `:preference_provider` is set while `:user_preference` is not, a warning logs
  once per VM with what applies and how to wire up the bridge. Nobody should
  have to discover this the way it was discovered.

### Fixed

- The regression guard for the per-recipient verdict (0.6.1) **measured the
  mechanism, not the property**: it required the literal `allows_receipt?/4`
  line to appear inside `email.ex` and `in_app.ex`. When the six copied blocks
  were replaced by a shared function the guard went red — while the property it
  exists to protect was untouched.

  It now measures the verdict: no delivery path may derive consent from
  `context.user`, and every path that decides at all passes the RECEIPT first.
  The files are enumerated with a glob rather than a list someone maintains,
  because a maintained list is the other half of the same mistake — a transport
  added tomorrow is covered without anyone having to remember it.

## [0.6.14] - 2026-09-09

### Added

- **`metadata.secret_env` — the signing secret's NAME in the DSL, the value at
  send time.** Channels declared in `dispatch do` are compile-time data, but a
  signing secret is operational data. Baked in at compile time, a key rotation
  does not take effect until someone recompiles — and nothing says a word.

  The alternative was to move the whole channel into the event module's
  `channels/1`, which works but sacrifices the DSL for every OTHER property of
  the channel (audience, timing, policy, dedupe). Reading the name at compile
  time and the value at send time keeps both: the channel stays declarative,
  the secret stays operational.

- **`metadata.webhook_url_env`** for the same reason, with a sharper
  consequence: a URL baked in at compile time travels to STAGING, and staging
  then posts to production's receiver. The message arrives — just in the wrong
  place, which does not look like a failure.

- **The envelope carries `source_type` and `source_id`.** Without them a
  receiver knows something happened and to whom, but not about WHICH object —
  and therefore cannot offer an action. A Slack button that should record a
  choice on a meeting needs the meeting's id. The receipt already carried the
  fields; they were simply missing from the envelope.

  `secret` wins when both are given, so a test can set an explicit value.
  `secret_env` is stripped from the forwarded envelope for the same reason as
  `secret`: it reveals no value, but it is configuration rather than event
  data. `secret/1` is public.

## [0.6.13] - 2026-09-08

### Fixed

- **The receipt was scheduled AFTER the job was enqueued, and raced its own
  worker.** From the moment the job is in the queue a worker can pick it up —
  and with `Oban, testing: :inline` it already runs inside `Oban.insert/1`. The
  receipt could therefore become `:sending`, `:sent` or `:failed` before the
  transport marked `:scheduled`, and `schedule` only goes from `:pending`. The
  result was a raised `NoMatchingTransition` in the middle of a **successful**
  delivery: the message arrived, but the caller got an error.

  `:webhook` now marks `:scheduled` before the insert, and re-reads the receipt
  afterwards so the reported status is the real one rather than the expected
  one.

  The same ordering exists in `:slack` and `:discord`. They are untouched here
  — that is a behaviour change for existing consumers and belongs in its own
  change — but the bug is the same and worth knowing about.

## [0.6.12] - 2026-09-08

### Added

- **`:webhook` now actually delivers.** The transport had been in the registry
  and in `@type transport` for a long time, but `deliver/4` logged
  `"Webhook transport not yet implemented"` and marked the receipt `:skipped`
  with `transport_not_implemented`. A channel wired to it therefore sent
  nothing — and did so *silently*: the receipt was a valid terminal status, not
  an error, so no surface upstream had reason to raise anything. That is the
  worst kind, because it only shows up when someone wonders why a notification
  never came.

  The transport now POSTs a stable envelope shape (`event_id`, `receipt_id`,
  `user_id`, `recipient`, `audience`, `content`, `metadata`, `sent_at`) through
  `SendWebhook`, so a receiver can be written once.

- **Signing.** With `metadata.secret` set, the call carries
  `<signature_header>: sha256=<hex>` (default `x-webhook-signature`), computed
  as HMAC-SHA256 over `METHOD \n path \n sorted_query \n body`. Binding the
  path and the query — not only the body — means an intercepted signature
  cannot be replayed against a different endpoint on the same host.
  `canonical_string/3` is public so a receiver can test its verifier against
  ours rather than against its reading of the documentation.

  The secret is stripped from the forwarded metadata: a signing secret must
  never travel inside the body it signs.

- **`SendWebhook` accepts `raw_body`.** A signed webhook must send exactly the
  bytes that were signed. Let the HTTP client re-encode a map and key order and
  float formatting can change, and the signature fails *intermittently* — which
  is worse than always, because it looks like a flake rather than a bug. The
  transport therefore serialises itself and passes the string on. Without
  `raw_body` the behaviour is unchanged (`json: payload`), so the Discord and
  Slack transports are untouched.

- **A `4xx` is no longer retried.** `SendWebhook` treated every non-2xx the
  same and let Oban try five times. But a `4xx` is the receiver saying *this
  request is wrong* — an unknown channel, a revoked webhook URL, a recipient
  that does not exist. Resending exactly the same bytes changes nothing; it
  only hides the failure behind a queue that looks busy. It is now
  `{:cancel, reason}` with the receipt already set to `failed`. The exceptions
  are `408` and `429`, which are about time rather than content, and
  `5xx`/network errors as before.

  This lets a receiver answer `422` when a notification cannot be delivered and
  get an honest `failed` receipt on the first attempt, rather than five
  identical attempts and a truth that arrives minutes later. `permanent?/1` is
  public.

- **The signing secret can no longer be dropped silently.** `metadata` was read
  with an atom key only, while the strip from the payload handled both atom and
  string. A `metadata: %{"secret" => …}` was therefore stripped from the body
  but never used — the call went out unsigned, without a word. The read now
  mirrors `ContentMap.get_content/2` and takes both forms.
  `request_headers/3` is public so the signing contract can be tested from the
  outside.

### Notes

- `:webhook` honours the recipient's opt-out through
  `UserPreference.allows_receipt?/4`, like `:email` and `:in_app` — a webhook
  is often the first hop to a person, and delivering to someone who opted out
  because the last hop happens to be HTTP would be the wrong default.
  `:slack`, `:discord`, `:sms` and `:push` do not yet make that check. It looks
  like a gap rather than a decision, but changing them is a behaviour change
  for existing consumers and belongs in its own change.

## [0.6.11] - 2026-09-07

### Fixed

- **The in-app notification could be delivered once per RECIPIENT rather than
  once per event.** The idempotency key was built by `extract_resource_id/1`,
  which takes the first value in `data` carrying a binary `:id`. When `data`
  holds both the recipient and the thing that happened, the winner is decided
  by the map's iteration order — in practice often the recipient. The key then
  becomes `event:<user>:<audience>:<user>`, constant across all future events
  for that user, and every later event collides with the first. Seen in
  production on a "you reached your goal" event: ONE row in the whole table,
  the rest collided.

  Channels now take `idempotency_source:` — the key in `data` that identifies
  which event this is. Without it the old heuristic applies unchanged, so
  existing events behave the same.

- **A collision could leave the transport as an exception.** `Ash.create`
  returns `{:error, _}` for a uniqueness violation only when it owns the
  transaction. Inside an OUTER transaction — an Ash action dispatching from a
  hook — AshPostgres raises instead, the `case` statement's error branch is
  never reached, and the raise tears down the caller's transaction along with
  everything it had done. A trigger stamping its own idempotency flag before
  sending would then lose the stamp and run again forever. The transport now
  looks the key up before the insert and treats a *raised* uniqueness violation
  as the collision it is.

- **A retry on a receipt that already carries `notification_id` does not create
  a second notification.** The retry path builds the key from the receipt's
  `source_id` and cannot see the channel's `idempotency_source`, so it could
  write a duplicate under a different key. It now acknowledges instead.

## [0.6.10] - 2026-09-02

### Fixed

- **An unreachable recipient no longer takes down the whole channel.** When
  `extract_identifier/4` could not produce an address,
  `extract_recipient_identifier/3` re-raised, and the exception escaped
  `Enum.map/2` in `do_dispatch_channel/3` — even though that function already
  tolerates partial failure and returns success when at least one delivery went
  through. A recipient without an address therefore cost ALL recipients in the
  channel. It now returns `{:error, :recipient_unreachable}` for that row only;
  the error is logged as before.

  Seen in production on 2026-09-02: an audience resolved to the buyer plus
  their company, the company was a login-less grouping row with no email
  address, and the customer's order confirmation was never created. The buyer
  had a perfectly good address and lost their email to someone else's missing
  one.

  Distinct from the `optional: true` skip, which is a deliberate skip and
  counts as success. Merging the two would have reported a channel as delivered
  even though nobody could be reached.

- **The error message stops being the thing that breaks.**
  `raise_extraction_error/5` read `recipient.__struct__` directly. Audiences
  can resolve to plain maps, and on one of those the dot access raised a
  `KeyError` *inside the error message* — the caller saw
  `%KeyError{key: :__struct__}` rather than which recipient and which field it
  was about. The one line that could have explained the failure was the one
  that broke.

## [0.6.9] - 2026-08-24

### Fixed

- **`:send_now` and `:reopen` accept nothing now.** Neither declared an
  `accept` list, so both inherited the resource default: **thirty attributes**,
  including `recipient`, `subject`, `body_html` and `content`.

  "Send this letter again" could therefore be called as "send a different
  letter to a different address" — and because the same call rewrites the
  receipt, nothing in the record would say otherwise afterwards. The receipt is
  the audit trail; an action that edits it while sending it destroys the only
  evidence of what was sent.

  A resend has no inputs. It re-sends what is already there.

  **Breaking if you were passing attributes to `:send_now`** — those calls will
  now fail with `NoSuchInput` instead of silently editing the outgoing mail.
  Change the receipt first with an ordinary update if that was deliberate, then
  send. `:reopen` shipped in 0.6.8 and cannot have dependents yet.

## [0.6.8] - 2026-08-23

### Added

- **`:reopen` — a way out of `:failed_permanent`.** The state was a dead end:
  no transition led out of it, `:send_now` refused it explicitly, and
  `SendEmail` treats it as terminal and completes any job for it as a success.
  A receipt that ended there could never be sent again — not even by a person
  who had just fixed the reason it failed. The only remaining move was to look
  at it.

  That is the wrong shape for the state that a permanent failure lands in. It
  is reached in ordinary operation (a provider outage, a rate limit, a
  mailbox that was full for a day), and every one of those reasons goes away
  on its own.

  `:reopen` moves the receipt back to `:scheduled` and enqueues a job, so the
  existing send path runs unchanged. Three deliberate choices:

  - It starts **only** from `:failed_permanent`. A receipt that actually
    reached its recipient can never be re-sent through it.
  - It is gated by the same `send_now_authorizer` as `:send_now`, because it
    sends real mail.
  - It **resets** `retry_count` rather than incrementing it. The counter
    exists to stop the automatic sweep from looping forever; a human deciding
    to try again is not that loop, and leaving the counter at its ceiling
    would let the sweep abandon the attempt the moment it failed once.

  Consumers that want the old behaviour need do nothing: the action has to be
  called to have an effect, and nothing in the library calls it.

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
  guard. The behaviour is exercised end-to-end by a consumer's mailing
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
  now uses `AshDispatch.Config.gettext_domain/0`.

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
  fleet; two consumers expose unauthenticated receipt mutation today.
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
  to type-check in consumers running `strict: true` because
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
