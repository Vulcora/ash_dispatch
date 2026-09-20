defmodule AshDispatch.SMSBackend do
  @moduledoc """
  Beteendet en SMS-backend implementerar.

      config :ash_dispatch, :sms_backend, MyApp.SMS

  `AshDispatch.SMSBackend.Elks` följer med biblioteket och räcker för 46elks;
  det här beteendet är för alla andra leverantörer.

  ## Var den anropas ifrån

  Från `AshDispatch.Workers.SendSMS`, inte från transporten. Transporten köar
  ett jobb och sätter kvittot `:scheduled`; workern markerar `:sending` och
  anropar `deliver/4`. Backenden behöver alltså inte oroa sig för att hålla
  en databastransaktion öppen — men den ska inte heller anta att den körs
  synkront med den action som utlöste eventet.

  Kräver en Oban-kö vid namn `:sms`.

  Jobbet bär bara kvitto-id:t, så kontexten workern skickar är rekonstruerad
  ur kvittot: `event_id` och `audience` stämmer, men `data` och `variables` är
  tomma. Behöver backenden något av det ska det läsas ur `receipt.content`,
  som frystes när kvittot skapades och därför överlever ett omförsök.

  ## Kontraktet

  - Läs `receipt.recipient` (telefonnumret) och SMS-texten ur
    `receipt.content`. Använd `AshDispatch.ContentMap.get_content/2`:
    kolumnen är JSONB, så en färsk struct bär atomnycklar medan en som läst
    tillbaka ur Postgres bär strängnycklar. Dispatchern skriver `:message`.
  - Skicka via leverantörens API.
  - **Markera kvittot själv.** Backenden vet vilka fel som är permanenta:
    - klart: `ReceiptStatus.mark_sent(receipt, %{"id" => leverantörens_id})`
    - går att göra om: `ReceiptStatus.mark_failed(receipt, orsak)`
    - aldrig bättre: `ReceiptStatus.mark_failed_permanent(receipt, orsak)`
  - Returnera `{:ok, uppdaterat_kvitto}` eller `{:error, orsak}`.

  Ett `{:error, _}` får workern att markera `:failed` och låta Oban göra om.
  Ett ogiltigt telefonnummer eller fel inloggningsuppgifter hör hemma i
  `mark_failed_permanent` — de blir inte rätt av fem omförsök, och så länge de
  ligger kvar som `:failed` fördröjer de bara beskedet till människan som ska
  rätta dem.

  ## Mottagarfältet

  Utan en `:sms`-post i `recipient_fields` kastar **varje** mottagare
  `"No identifier field configured for sms transport"`, och felet säger inte
  var man ska leta:

      config :ash_dispatch,
        recipient_fields: [
          sms: [identifier: :phone, name: [:display_name, :name]]
        ]
  """

  @callback deliver(
              receipt :: struct(),
              context :: AshDispatch.Context.t(),
              channel :: AshDispatch.Channel.t(),
              event_config :: map()
            ) :: {:ok, struct()} | {:error, term()}
end
