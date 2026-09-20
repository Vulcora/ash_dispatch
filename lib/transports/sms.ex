defmodule AshDispatch.Transports.SMS do
  use AshDispatch.Transport, atom: :sms, skip_receipt?: false

  @moduledoc """
  SMS-transport — köar ett jobb som anropar den konfigurerade backenden.

      config :ash_dispatch, :sms_backend, MyApp.SMS

  Modulen ska implementera `AshDispatch.SMSBackend`. Saknas den markeras
  kvittot `:skipped` med `error_message: "transport_not_implemented"`, precis
  som förr.

  ## Vägen

  ```
  pending → scheduled (jobb köat)
          ↘ skipped   (mottagaren har tackat nej)

  senare, i AshDispatch.Workers.SendSMS:
  scheduled → sending → sent
                      ↘ failed  (görs om)
  ```

  ## Vad som ändrades

  Transporten anropade tidigare `backend.deliver/4` **synkront**. Dispatchen
  sker i en `after_action`-hook inuti actionens transaktion, så en långsam
  leverantör höll transaktionen öppen, `time:` gick inte att använda, och ett
  misslyckat SMS kunde inte göras om — `RetryFailedDeliveries` känner bara
  igen transporter som har en worker.

  Nu gäller samma form som e-posten: samtycke, kö, `:scheduled`. En backend
  som redan skickar synkront fungerar oförändrat — den anropas bara från
  workern i stället för från transaktionen.

  Kräver en Oban-kö vid namn `:sms`.

  ## Fördröjd leverans

  Faller ut ur kön, precis som för e-post:

      channel = %Channel{transport: :sms, time: {:in, 300}}
      channel = %Channel{transport: :sms, time: {:at, ~U[2026-09-21 06:00:00Z]}}

  ## Mottagarfältet

  `config :ash_dispatch, :recipient_fields` **måste** ha en `:sms`-post,
  annars kastar varje mottagare `"No identifier field configured for sms
  transport"`:

      recipient_fields: [
        sms: [identifier: :phone, name: [:display_name, :name]]
      ]
  """

  require Logger

  alias AshDispatch.Transports.Email
  alias AshDispatch.Transports.Preferences

  def deliver(receipt, context, channel, event_config) do
    Preferences.with_consent(receipt, context, channel, event_config, fn ->
      leverera(receipt, context, channel)
    end)
  end

  # Samtyckesgrinden sitter ovanför kön med flit: ett kvitto som mottagaren
  # tackat nej till ska aldrig bli ett jobb.
  defp leverera(receipt, context, channel) do
    case AshDispatch.Config.sms_backend() do
      nil ->
        Logger.info("SMS transport not yet implemented (no :sms_backend configured), skipping")

        receipt
        |> Ash.Changeset.for_update(:skip, %{error_message: "transport_not_implemented"})
        |> Ash.update!(authorize?: false)
        |> then(&{:ok, &1})

      _backend ->
        result = enqueue(receipt, channel)
        {:ok, update_receipt_with_job(receipt, result)}
    end
  rescue
    error ->
      Logger.error("""
      SMS transport failed to enqueue job
      Event: #{context.event_id}
      Error: #{inspect(error)}
      """)

      {:error, error}
  end

  defp enqueue(receipt, channel) do
    # Bara kvitto-id:t. Texten och mottagaren står i kvittot, och det är
    # meningen: en omkörning ska aldrig kunna skicka något annat än det som
    # en gång frystes.
    changeset =
      AshDispatch.Workers.SendSMS.new(%{"receipt_id" => receipt.id},
        schedule_in: Email.schedule_seconds(channel)
      )

    case Oban.insert(changeset) do
      {:ok, job} ->
        Logger.debug("Enqueued SMS job #{job.id} for receipt #{receipt.id}")
        {:ok, job}

      {:error, error} ->
        Logger.error("Failed to enqueue SMS job: #{inspect(error)}")
        {:error, error}
    end
  end

  defp update_receipt_with_job(receipt, {:ok, job}) do
    # Läs om: i Obans inline-läge har workern redan kört färdigt och kvittot
    # är inte längre :pending.
    case Ash.get(receipt.__struct__, receipt.id, authorize?: false) do
      {:ok, %{status: :pending} = current} ->
        current
        |> Ash.Changeset.for_update(:schedule, %{oban_job_id: job.id})
        |> Ash.update!(authorize?: false)

      {:ok, current} ->
        Logger.debug(
          "Receipt #{receipt.id} already in #{current.status} state, skipping schedule"
        )

        current

      {:error, _} ->
        receipt
    end
  end

  defp update_receipt_with_job(receipt, {:error, reason}) do
    receipt
    |> Ash.Changeset.for_update(:mark_failed, %{error_message: inspect(reason)})
    |> Ash.update!(authorize?: false)
  end
end
