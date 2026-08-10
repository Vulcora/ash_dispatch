defmodule AshDispatch.Workers.ScrubSensitiveContent do
  @moduledoc """
  Cron worker that blanks stored bodies of receipts whose event declares
  `metadata: [sensitive_content: true]`.

  The receipt-first pattern stores full rendered content, which for OTP
  codes and password-reset links means live secrets in the database. Once a
  receipt is older than `config :ash_dispatch, :scrub_after_hours` (default
  24), its `body_text` is replaced with a marker and `body_html` cleared.
  Recipient, subject, status and delivery timestamps are untouched.

  Receipts in `:failed` are skipped so the retry path can still resend the
  original content; they are scrubbed once they reach a terminal state.

  ## Configuration

      # On the event, in the dispatch DSL:
      event(:password_reset,
        ...,
        metadata: [sensitive_content: true])

      # Optional retention window (hours):
      config :ash_dispatch, scrub_after_hours: 24

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

  @doc "The replacement text written into scrubbed `body_text` fields."
  def marker, do: @marker

  @impl Oban.Worker
  def perform(_job) do
    case sensitive_event_ids() do
      [] ->
        :ok

      event_ids ->
        hours = Application.get_env(:ash_dispatch, :scrub_after_hours, 24)
        cutoff = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)
        table = receipt_table()

        {count, _} =
          Config.repo().update_all(
            from(r in table,
              where: r.event_id in ^event_ids,
              where: r.inserted_at < ^cutoff,
              where: r.status != "failed",
              where: not is_nil(r.body_text) and r.body_text != ^@marker
            ),
            set: [body_text: @marker, body_html: nil]
          )

        if count > 0, do: Logger.info("ScrubSensitiveContent: scrubbed #{count} receipt bodies")
        :ok
    end
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
