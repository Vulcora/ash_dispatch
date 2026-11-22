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
  points at a deleted notification keeps its `notification_id`: the
  relationship is `on_delete: :nilify` in `DeliveryReceipt.Base`, so the
  database clears it.

  Each pass deletes at most `:prune_batch_size` rows (default 5000) per table,
  so one run cannot lock a large table for minutes. What is left goes on the
  next run.

  ## Per tenant

  One pass per tenant, like the scrub: the scheduled job reads
  `config :ash_dispatch, tenants:` and fans out, each pass pruning its own
  schema. See `AshDispatch.Tenancy.Cron`.

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
    case AshDispatch.Tenancy.Cron.plan(args) do
      {:run, tenant} -> prune(tenant)
      {:fan_out, tenants} -> AshDispatch.Tenancy.Cron.fan_out(__MODULE__, tenants)
      :no_tenants -> AshDispatch.Tenancy.Cron.no_tenants(__MODULE__)
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
        {count, _} = Config.repo().update_all(body_query(table, cutoff), [], prefix_opts(tenant))
        count

      :error ->
        0
    end
  end

  defp delete_receipts(_tenant, nil), do: 0

  defp delete_receipts(tenant, cutoff) do
    case receipt_table() do
      {:ok, table} ->
        {count, _} = Config.repo().delete_all(receipt_query(table, cutoff), prefix_opts(tenant))
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
          Config.repo().delete_all(notification_query(table, cutoff), prefix_opts(tenant))

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
    ids =
      from(r in table,
        where: r.status in ^@terminal,
        where: r.inserted_at < ^cutoff,
        where:
          (not is_nil(r.body_text) and r.body_text != ^@marker) or not is_nil(r.body_html) or
            fragment("(? \\?| array['html_body', 'text_body', 'message', 'body'])", r.content),
        select: r.id,
        limit: ^batch_size()
      )

    from(r in table,
      where: r.id in subquery(ids),
      update: [
        set: [
          body_text: ^@marker,
          body_html: nil,
          content: fragment("(? - 'html_body' - 'text_body' - 'message' - 'body')", r.content)
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
    |> limited(table)
  end

  @doc false
  # `occurred_at` is when the thing happened, which is what retention is
  # about; `inserted_at` is the fallback for a notification resource that has
  # no `occurred_at` of its own.
  def notification_query(table, cutoff) do
    from(n in table, where: coalesce(n.occurred_at, n.inserted_at) < ^cutoff)
    |> limited(table)
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  # A batch, through a subquery on the primary key: `delete_all` and
  # `update_all` take no `limit` of their own in Postgres. One pass therefore
  # cannot hold a lock on a large table for minutes, and what is left goes on
  # the next run.
  defp limited(query, table) do
    ids = from(q in query, select: q.id, limit: ^batch_size())

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

  defp prefix_opts(nil), do: []
  defp prefix_opts(tenant), do: [prefix: AshDispatch.Tenancy.receipt_prefix(tenant)]

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
  end

  defp where(nil), do: ""
  defp where(tenant), do: " in #{inspect(tenant)}"
end
