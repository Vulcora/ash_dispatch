defmodule AshDispatch.Workers.ScrubSensitiveContent do
  @moduledoc """
  Cron worker that blanks stored bodies of receipts whose event declares
  `metadata: [sensitive_content: true]`.

  The receipt-first pattern stores full rendered content, which for OTP
  codes and password-reset links means live secrets in the database. Once a
  receipt is older than `config :ash_dispatch, :scrub_after_hours` (default
  24), its `body_text` is replaced with a marker, `body_html` cleared and the
  copies of the text in `content` (`html_body`, `text_body`, and an SMS's
  `message` and `body`) removed.
  Recipient, subject, status and delivery timestamps are untouched.

  Terminal receipts (`:sent`, `:skipped`, `:failed_permanent`) are scrubbed
  after that window. A scheduled or failed receipt may still be sent — a delivery
  delayed past the window, a stalled queue, a retry — and the receipt is where a
  sensitive event's worker reads the body, so anything else waits for
  `config :ash_dispatch, :scrub_stranded_after_hours` (default 168, never shorter
  than the window). That cap is scrubbed whatever the status: a receipt stranded
  in `:sending` or `:pending` has no way forward and nothing sweeps it, and a
  live secret must not stay forever. A letter still waiting at the cap is refused
  by the worker instead of being sent empty.

  Attachments are not touched: they live in the `SendEmail` job's args until the
  Pruner removes the job. See `AshDispatch.Transports.Email.job_args/3`.

  ## Configuration

      # On the event, in the dispatch DSL:
      event(:password_reset,
        ...,
        metadata: [sensitive_content: true])

      # Optional retention windows (hours):
      config :ash_dispatch, scrub_after_hours: 24, scrub_stranded_after_hours: 168

  ## Scheduling

      config :my_app, Oban,
        plugins: [
          {Oban.Plugins.Cron,
           crontab: [
             {"20 3 * * *", AshDispatch.Workers.ScrubSensitiveContent}
           ]}
        ]
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query

  alias AshDispatch.Config
  alias AshDispatch.EventRegistry

  require Logger

  @marker "[scrubbed: sensitive content past retention window]"

  # Nothing is left to send from these. Any other status may still reach the
  # worker, which for a sensitive event reads the body from the receipt alone,
  # so it gets the longer `@stranded_hours`.
  @terminal ["sent", "skipped", "failed_permanent"]
  @stranded_hours 7 * 24

  @doc "The replacement text written into scrubbed `body_text` fields."
  def marker, do: @marker

  @impl Oban.Worker
  def perform(_job) do
    case sensitive_event_ids() do
      [] ->
        :ok

      event_ids ->
        {cutoff, stranded_cutoff} = cutoffs(DateTime.utc_now())

        {count, _} =
          Config.repo().update_all(
            scrub_query(receipt_table(), event_ids, cutoff, stranded_cutoff),
            []
          )

        if count > 0, do: Logger.info("ScrubSensitiveContent: scrubbed #{count} receipt bodies")
        :ok
    end
  end

  @doc false
  # The two limits: `{cutoff, stranded_cutoff}`. The cap is never shorter than
  # the window, so raising the window alone cannot scrub a waiting letter early.
  def cutoffs(now) do
    hours = Application.get_env(:ash_dispatch, :scrub_after_hours, 24)
    stranded = Application.get_env(:ash_dispatch, :scrub_stranded_after_hours, @stranded_hours)

    {DateTime.add(now, -hours * 3600, :second),
     DateTime.add(now, -max(hours, stranded) * 3600, :second)}
  end

  @doc false
  # The receipts to scrub and what they become. The rendered bodies live twice
  # on an email receipt: in `body_text`/`body_html` and again under
  # `html_body`/`text_body` in `content` (the dispatcher stores the whole
  # rendered content map), so both are emptied, and an SMS keeps its text only
  # in `content` (`message`, `body`). A receipt already carrying the
  # marker is picked up again while its content still holds a body, so
  # receipts scrubbed before 0.8.7 lose the copy too.
  def scrub_query(table, event_ids, cutoff, stranded_cutoff) do
    from(r in table,
      where: r.event_id in ^event_ids,
      where:
        (r.status in ^@terminal and r.inserted_at < ^cutoff) or r.inserted_at < ^stranded_cutoff,
      where:
        (not is_nil(r.body_text) and r.body_text != ^@marker) or not is_nil(r.body_html) or
          fragment("(? \\?| array['html_body', 'text_body', 'message', 'body'])", r.content),
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
  def sensitive_event_ids(otp_app \\ Config.otp_app()) do
    otp_app
    |> EventRegistry.all_events()
    |> Enum.filter(fn event -> get_in(event, [:metadata, :sensitive_content]) == true end)
    |> Enum.map(& &1.event_id)
  end

  defp receipt_table do
    AshPostgres.DataLayer.Info.table(Config.delivery_receipt_resource())
  end
end
