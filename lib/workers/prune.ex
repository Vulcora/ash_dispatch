defmodule AshDispatch.Workers.Prune do
  @moduledoc """
  Cron worker that enforces retention: empties old bodies, and removes old
  receipts and notifications.

  `AshDispatch.Workers.ScrubSensitiveContent` covers the events a host has
  marked `sensitive_content: true`. Everything else a receipt holds is kept
  forever — and a rendered letter is a letter: a name, an address, an order, a
  booking, a diagnosis. BACKLOG 3 said there was no retention or pruning at
  all for receipts or notifications, and three hosts wrote their own.

  ## Inert until you ask

  All three windows are **unset** by default, and an unset window prunes
  nothing. A host that schedules this worker and configures no window has a
  job that reads no rows and deletes none — which is the only safe default for
  a worker whose job is to delete things.

      config :ash_dispatch,
        # Empty the stored bodies of receipts older than this. The receipt
        # stays: who was written to, about what, when, and whether it arrived.
        body_retention_hours: 24 * 90,

        # Delete receipts older than this, bodies and all.
        receipt_retention_hours: 24 * 365,

        # Delete notifications older than this.
        notification_retention_hours: 24 * 180

  Hours, like the scrub's windows, so the three read the same way.

  ## What each one does

  **`body_retention_hours`** blanks `body_text` and `body_html` and removes
  the rendered copies from `content` (`html_body`, `text_body`, and an SMS's
  `message` and `body`) — the same fields the scrub empties, and with a marker
  of its own so the two are tellable apart afterwards. It touches only
  **terminal** receipts (`sent`, `skipped`, `failed_permanent`, `digested`):
  anything else may still be sent, and for a sensitive event the receipt is
  where the worker reads the body.

  **`receipt_retention_hours`** deletes the row. Only terminal receipts again,
  for the same reason, and never shorter than the body window in effect: a
  receipt is deleted at the later of the two, so configuring only the shorter
  one cannot delete a receipt whose body you meant to keep.

  **`notification_retention_hours`** deletes notifications whose
  `occurred_at` (or `inserted_at`) is older than the window. A receipt that
  pointed at a deleted notification has its `notification_id` set to NULL by
  the database: `DeliveryReceipt.Base` declares
  `reference(:notification, on_delete: :nilify)`, so the receipt survives the
  notification and stops claiming to link to it.

  Each pass deletes at most `:prune_batch_size` rows (default 5000) per table,
  so one run cannot lock a large table for minutes. What is left goes on the
  next run, and a pass that took a full batch says so in the log — a nightly
  cron that fills its batch every night never catches up.

  The batch is per PASS, and with receipts per tenant there is one pass per
  tenant: a hundred tenants is up to a hundred batches per table per run, in
  sequence. On a PUBLIC table the whole run is one batch, however many tenants
  the host has, because there is one pass. Size the batch for the shape you
  have.

  ## Per tenant

  One pass per tenant, like the scrub: the scheduled job reads
  `config :ash_dispatch, tenants:` and fans out, each pass pruning its own
  schema. See `AshDispatch.Tenancy.Cron`.

  Receipts and notifications take multitenancy **independently**, so each
  table is addressed with its own resource's prefix and the fan-out happens
  when *either* is per tenant. A host with per-tenant notifications and public
  receipts is a supported shape, and so is the other way round.

  The windows are checked BEFORE the fan-out: with none configured there is
  nothing to do in any schema, and a job per tenant per night to discover that
  is not nothing.

  ## Scheduling

      config :my_app, Oban,
        plugins: [
          {Oban.Plugins.Cron,
           crontab: [
             {"40 3 * * *", AshDispatch.Workers.Prune}
           ]}
        ]

  Nightly is enough: retention is measured in days and a pass that finds
  nothing still costs three queries.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query

  alias AshDispatch.Config

  require Logger

  @marker "[removed: past retention window]"
  @terminal ["sent", "skipped", "failed_permanent", "digested"]
  @default_batch_size 5000

  @doc "The replacement text written into emptied `body_text` fields."
  @spec marker() :: String.t()
  def marker, do: @marker

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    # Inertness FIRST. With no window configured there is nothing to do in any
    # schema, and fanning out one job per tenant to discover that is a job per
    # tenant per night for a host that has not decided its retention yet.
    if windows() == %{body: nil, receipt: nil, notification: nil} do
      :ok
    else
      # Either resource being per tenant means the pass has to run per tenant.
      # The two take multitenancy independently, and a host can have
      # per-tenant notifications with public receipts.
      per_tenant? =
        AshDispatch.Tenancy.receipts_per_tenant?() or
          AshDispatch.Tenancy.notifications_per_tenant?()

      case AshDispatch.Tenancy.Cron.plan(args, per_tenant?) do
        {:run, tenant} -> prune(tenant)
        {:fan_out, tenants} -> AshDispatch.Tenancy.Cron.fan_out(__MODULE__, tenants)
        :no_tenants -> AshDispatch.Tenancy.Cron.no_tenants(__MODULE__)
      end
    end
  end

  @doc """
  The three windows in hours, as configured. `nil` for each one unset.
  """
  @spec windows() :: %{
          body: pos_integer() | nil,
          receipt: pos_integer() | nil,
          notification: pos_integer() | nil
        }
  def windows do
    %{
      body: hours(:body_retention_hours),
      receipt: hours(:receipt_retention_hours),
      notification: hours(:notification_retention_hours)
    }
  end

  @doc false
  # The cut-off for a window, or `nil` when the window is unset.
  @spec cutoff(pos_integer() | nil, DateTime.t()) :: DateTime.t() | nil
  def cutoff(nil, _now), do: nil
  def cutoff(hours, now), do: DateTime.add(now, -hours * 3600, :second)

  @doc false
  # A receipt is deleted at the LATER of the two windows. Configuring only
  # `receipt_retention_hours`, shorter than the body window, would otherwise
  # delete the row before the body window it was told to respect had passed —
  # and the row is the audit trail the body window exists to keep.
  @spec receipt_cutoff(map(), DateTime.t()) :: DateTime.t() | nil
  def receipt_cutoff(%{receipt: nil}, _now), do: nil

  def receipt_cutoff(%{receipt: receipt, body: body}, now) do
    cutoff(max(receipt, body || receipt), now)
  end

  defp prune(tenant) do
    windows = windows()
    now = AshDispatch.Clock.utc_now()

    if windows == %{body: nil, receipt: nil, notification: nil} do
      # Inert, and silent about it. A host that scheduled the worker before
      # deciding its retention does not need a line a night.
      :ok
    else
      counts = %{
        bodies: empty_bodies(tenant, cutoff(windows.body, now)),
        receipts: delete_receipts(tenant, receipt_cutoff(windows, now)),
        notifications: delete_notifications(tenant, cutoff(windows.notification, now))
      }

      log(counts, tenant)
      :ok
    end
  rescue
    error ->
      # A pass that cannot read must not take the crontab down with it, and
      # must not report success either.
      Logger.error("Prune: pass failed#{where(tenant)}: #{Exception.message(error)}")
      {:error, Exception.message(error)}
  end

  # ── The three passes ────────────────────────────────────────────────

  defp empty_bodies(_tenant, nil), do: 0

  defp empty_bodies(tenant, cutoff) do
    case receipt_table() do
      {:ok, table} ->
        {count, _} =
          Config.repo().update_all(
            body_query(table, cutoff),
            [],
            prefix_opts(Config.delivery_receipt_resource(), tenant)
          )

        count

      :error ->
        0
    end
  end

  defp delete_receipts(_tenant, nil), do: 0

  defp delete_receipts(tenant, cutoff) do
    case receipt_table() do
      {:ok, table} ->
        {count, _} =
          Config.repo().delete_all(
            receipt_query(table, cutoff),
            prefix_opts(Config.delivery_receipt_resource(), tenant)
          )

        count

      :error ->
        0
    end
  end

  defp delete_notifications(_tenant, nil), do: 0

  defp delete_notifications(tenant, cutoff) do
    case notification_table() do
      {:ok, table} ->
        {count, _} =
          Config.repo().delete_all(
            notification_query(table, cutoff),
            prefix_opts(Config.notification_resource(), tenant)
          )

        count

      :error ->
        0
    end
  end

  @doc false
  # The receipts whose bodies are emptied, and what they become. A rendered
  # email body lives twice — in `body_text`/`body_html` and again under
  # `html_body`/`text_body` in `content`, where the dispatcher stores the whole
  # rendered map — so both are emptied, and an SMS keeps its text only in
  # `content` (`message`, `body`). Public-but-undocumented so the jsonb
  # operators can be tested against a real Postgres, which is the only place
  # they mean anything.
  def body_query(table, cutoff) do
    # The batch subquery is built here rather than through `limited/2`: that
    # one wraps the query in a fresh `from`, which would DISCARD the `update:`
    # clause below and leave Ecto raising "requires at least one field to be
    # updated". The test against a real Postgres is what found it.
    #
    # `content['digest']['item']['summary']` is the fourth place a body lives:
    # a batched email stores the first 280 characters of its text under there
    # for the digest to list (`AshDispatch.Digest.item/3`). Leaving it was
    # worse than missing it once — the row is never SELECTED again after the
    # first pass, so the paragraph stayed for good.
    ids =
      from(r in table,
        where: r.status in ^@terminal,
        where: r.inserted_at < ^cutoff,
        # `jsonb_typeof(...) = 'object'` first: `?|` raises on a jsonb
        # that is not an object, and `content['digest']['item']` is
        # whatever a host's own `digest_item/2` returned — a string, a
        # list, anything. One receipt shaped like that would have taken
        # down every pass.
        where:
          (not is_nil(r.body_text) and r.body_text != ^@marker) or not is_nil(r.body_html) or
            fragment("(? \\?| array['html_body', 'text_body', 'message', 'body'])", r.content) or
            fragment(
              "(jsonb_typeof(? #> '{digest,item}') = 'object' and (? #> '{digest,item}') \\?| array['summary', 'title'])",
              r.content,
              r.content
            ),
        select: r.id,
        # Oldest first, and deterministic: without an order the batch is
        # whatever the planner returns, so two passes can fight over the same
        # rows while older ones are never reached.
        order_by: [asc: r.inserted_at, asc: r.id],
        limit: ^batch_size()
      )

    from(r in table,
      where: r.id in subquery(ids),
      update: [
        set: [
          body_text: ^@marker,
          body_html: nil,
          # One expression, because `update_all` sets a column once.
          # `jsonb_set` with `create_if_missing = false` (the fourth argument)
          # leaves a receipt that was never batched untouched, so the nested
          # path costs nothing for the ordinary case.
          content:
            fragment(
              "jsonb_set(? - 'html_body' - 'text_body' - 'message' - 'body', '{digest,item}', coalesce((? #> '{digest,item}') - 'summary' - 'title', '{}'::jsonb), false)",
              r.content,
              r.content
            )
        ]
      ]
    )
  end

  @doc false
  def receipt_query(table, cutoff) do
    from(r in table,
      where: r.status in ^@terminal,
      where: r.inserted_at < ^cutoff
    )
    |> limited(table, :inserted_at)
  end

  @doc false
  # `occurred_at` is when the thing happened, which is what retention is
  # about; `inserted_at` is the fallback for a notification resource that has
  # no `occurred_at` of its own.
  def notification_query(table, cutoff) do
    from(n in table, where: coalesce(n.occurred_at, n.inserted_at) < ^cutoff)
    |> limited(table, :inserted_at)
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  # A batch, through a subquery on the primary key: `delete_all` and
  # `update_all` take no `limit` of their own in Postgres. One pass therefore
  # cannot hold a lock on a large table for minutes, and what is left goes on
  # the next run.
  defp limited(query, table, order_by) do
    # Oldest first, and deterministic. Without an order the batch is whatever
    # the planner returns, so two passes can fight over the same rows while
    # older ones are never reached at all.
    ids =
      from(q in query,
        select: q.id,
        order_by: [asc: field(q, ^order_by), asc: q.id],
        limit: ^batch_size()
      )

    from(r in table, where: r.id in subquery(ids))
  end

  defp batch_size do
    case Application.get_env(:ash_dispatch, :prune_batch_size, @default_batch_size) do
      size when is_integer(size) and size > 0 -> size
      _ -> @default_batch_size
    end
  end

  defp hours(key) do
    case Application.get_env(:ash_dispatch, key) do
      hours when is_integer(hours) and hours > 0 ->
        hours

      nil ->
        nil

      other ->
        Logger.warning(
          "[AshDispatch] config :ash_dispatch, #{key}: #{inspect(other)} is not a positive " <>
            "number of hours; nothing is pruned for it"
        )

        nil
    end
  end

  # Per RESOURCE, not per receipt. `receipt_prefix/1` answers for the receipt
  # resource, and using it for the notification table wrote the receipts'
  # schema name into a notification query — which for a host with per-tenant
  # notifications and public receipts means `nil`, deleting from `public`
  # across every tenant's rows, and for the other mix means a prefix that is
  # not the one the notifications live in.
  defp prefix_opts(_resource, nil), do: []

  defp prefix_opts(resource, tenant) do
    # `Tenancy.prefix/2` converts a tenant to a schema name; it does not ask
    # whether THIS resource lives in one. A resource that declares no
    # multitenancy must be addressed with no prefix at all, or a per-tenant
    # pass looks for `tenant_a.pt_public_notifications` and finds no such
    # relation — which is what a mixed configuration produced.
    with true <- AshDispatch.Tenancy.multitenant?(resource),
         prefix when is_binary(prefix) <- AshDispatch.Tenancy.prefix(resource, tenant) do
      [prefix: prefix]
    else
      _ -> []
    end
  end

  defp receipt_table, do: table_of(Config.delivery_receipt_resource())
  defp notification_table, do: table_of(Config.notification_resource())

  # `:error` rather than a raise: a host may have receipts and no notification
  # resource, or an ETS stand-in with no table at all, and the other passes
  # should still run.
  defp table_of(nil), do: :error

  defp table_of(resource) do
    case AshPostgres.DataLayer.Info.table(resource) do
      table when is_binary(table) and table != "" -> {:ok, table}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp log(%{bodies: 0, receipts: 0, notifications: 0}, _tenant), do: :ok

  defp log(counts, tenant) do
    Logger.info(
      "Prune: emptied #{counts.bodies} receipt bodies, deleted #{counts.receipts} receipts " <>
        "and #{counts.notifications} notifications#{where(tenant)}"
    )

    # A pass that took a FULL batch did not finish, and a nightly cron that
    # takes a full batch every night never catches up: the backlog grows while
    # the log says work is being done. Said once per pass, per table.
    batch = batch_size()

    for {what, count} <- counts, count >= batch do
      Logger.warning(
        "Prune: took a full batch of #{batch} #{what}#{where(tenant)} and stopped there. " <>
          "Run it more often, or raise :prune_batch_size, or the backlog will not shrink."
      )
    end

    :ok
  end

  defp where(nil), do: ""
  defp where(tenant), do: " in #{inspect(tenant)}"
end
