defmodule AshDispatch.Workers.SendSMS do
  @moduledoc """
  Skickar ett SMS-kvitto via den konfigurerade backenden.

  Spegling av `AshDispatch.Workers.SendEmail`, av samma skäl: dispatchen sker i
  en `after_action`-hook **inuti actionens transaktion**, och en utgående
  HTTPS-rundresa per mottagare hör inte hemma där. Transporten köar, workern
  skickar.

  Innan 0.6.11 anropade SMS-transporten backenden rakt av. Det betydde att en
  långsam eller nere SMS-leverantör höll actionens transaktion öppen, att
  `time:`-schemaläggning inte gick att använda, och att ett misslyckat utskick
  inte kunde göras om — `RetryFailedDeliveries` känner bara igen transporter
  som har en worker.

  ## Jobbargument

  - `receipt_id` — kvittots UUID. Allt annat läses ur kvittot, så en omkörning
    aldrig kan skicka en annan text än den som en gång frystes.
  """

  use Oban.Worker,
    queue: :sms,
    max_attempts: 5,
    # Ett jobb per kvitto. "Skicka nu" medan originalet ligger i kön ska inte
    # kunna bli två SMS till samma telefon.
    unique: [keys: [:receipt_id], states: [:available, :scheduled, :executing]]

  alias AshDispatch.Config
  alias AshDispatch.ReceiptStatus

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    receipt_id = args["receipt_id"]

    case Config.delivery_receipt_resource() |> Ash.get(receipt_id, authorize?: false) do
      {:ok, receipt} ->
        process_sms(receipt)

      {:error, error} ->
        Logger.error("Failed to fetch receipt #{receipt_id}: #{inspect(error)}")
        {:error, :receipt_not_found}
    end
  end

  @doc false
  # Bygger ett nytt jobb för ett kvitto. Används av retry-vägen, som inte har
  # några andra argument att bära med sig — texten ligger i kvittot.
  def new_for_receipt(receipt), do: new(%{receipt_id: receipt.id})

  defp process_sms(receipt) do
    # Terminalt läge: ett dubblettjobb ska sluta som framgång, inte som ett
    # andra SMS. Samma tidiga utträde som SendEmail.
    if receipt.status in [:sent, :skipped, :failed_permanent] do
      Logger.info(
        "Receipt #{receipt.id} already in terminal state #{receipt.status}, job completing as success"
      )

      :ok
    else
      case backend() do
        nil ->
          ReceiptStatus.mark_skipped(receipt, "transport_not_implemented")
          :ok

        backend ->
          send_with(backend, receipt)
      end
    end
  end

  defp send_with(backend, receipt) do
    case ReceiptStatus.mark_sending(receipt) do
      {:ok, receipt} ->
        deliver(backend, receipt)

      {:error, %Ash.Error.Invalid{errors: errors}} ->
        # Ett annat jobb hann före. Samma resonemang som i SendEmail: en
        # kapplöpning om samma kvitto är inte ett fel, den är en dubblett.
        if Enum.any?(errors, &match?(%AshStateMachine.Errors.NoMatchingTransition{}, &1)) do
          Logger.info(
            "Receipt #{receipt.id} state transition conflict (likely duplicate job), completing as success"
          )

          :ok
        else
          Logger.error("Receipt #{receipt.id} update failed: #{inspect(errors)}")
          {:error, errors}
        end

      {:error, reason} ->
        Logger.error("Receipt #{receipt.id} mark_sending failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Backenden äger sitt eget kvitto: den vet vilka fel som är permanenta
  # (ogiltigt nummer, fel inloggning) och vilka som är värda ett omförsök.
  # Därför markerar den själv, och vi tolkar bara utfallet för Obans skull.
  defp deliver(backend, receipt) do
    case backend.deliver(receipt, context_for(receipt), channel_for(receipt), %{}) do
      {:ok, %{status: status} = updated} when status in [:sent, :skipped, :failed_permanent] ->
        Logger.info("SMS #{status} for receipt #{updated.id}")
        :ok

      {:ok, %{status: :failed} = updated} ->
        # Oban gör om; kvittot bär redan felet.
        {:error, updated.error_message || "sms_failed"}

      {:ok, _other} ->
        :ok

      {:error, reason} ->
        # Backenden hann inte markera — gör det åt den, annars strandar
        # kvittot i :sending och fångas först av Stranded-cronen.
        ReceiptStatus.mark_failed(receipt, reason)
        Logger.error("SMS failed for receipt #{receipt.id}: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    error ->
      ReceiptStatus.mark_failed(receipt, error)
      Logger.error("SMS backend raised for receipt #{receipt.id}: #{inspect(error)}")
      {:error, error}
  end

  # Jobbet bär bara kvitto-id:t, så den ursprungliga kontexten finns inte kvar
  # — den innehåller godtycklig data och överlever inte en JSONB-rundresa.
  # Backenden får därför en rekonstruerad kontext med det som går att läsa ur
  # kvittot. `data` och `variables` är TOMMA här; en backend som behöver dem
  # ska läsa `receipt.content`, som är frusen vid skapandet och just därför
  # överlever ett omförsök.
  defp context_for(receipt) do
    %AshDispatch.Context{event_id: receipt.event_id, data: %{}, variables: %{}}
  end

  defp channel_for(receipt) do
    %AshDispatch.Channel{transport: :sms, audience: Map.get(receipt, :audience)}
  end

  defp backend, do: Config.sms_backend()
end
