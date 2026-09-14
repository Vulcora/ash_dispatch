defmodule AshDispatch.Transports.WebhookModuleContentTest do
  @moduledoc """
  Vad en MODULBASERAD händelse får bidra med till en webhook.

  ## Felet provet finns för

  `build_module_content/5` hade en gren per transport, och `:webhook` föll
  igenom till catch-allen — `%{message: notification_message(...)}` och inget
  annat. En modulbaserad webhook-händelse kunde alltså inte sätta en rubrik,
  och inte en väg vidare, hur gärna den än ville: `notification_title/2` och
  `action_url/2` anropades aldrig för den transporten.

  `:in_app` har alltid burit alla fyra. Att `:webhook` inte gjorde det var
  ingen deklaration — det var att ingen skrivit grenen.

  Mätt hos en konsument 2026-09-14: av sex distinkta kanalposter i produktion
  bar EN en rubrik och NOLL en länk. Det läste laget som slarv; vägen fanns
  inte.

  ## `extra_content/2`

  Transporternas innehåll är en sluten lista, och det räcker så länge
  mottagaren är en notislista. Det räcker inte när mottagaren är en Slack-yta
  som kan rendera fakta i två kolumner, flera knappar och en ikon — då är
  varje ny sådan nyckel annars en ändring i biblioteket.

  Provet nedan vaktar den regel som gör tillägget ofarligt: transportens egna
  nycklar VINNER. En modul som returnerar `%{message: ...}` i tillägget får
  inte tysta `notification_message/2`.
  """

  use ExUnit.Case, async: true

  alias AshDispatch.{Channel, Context}

  @dispatcher File.read!("lib/dispatcher.ex")

  defp module_content_kroppen do
    [_, body] = String.split(@dispatcher, "defp build_module_content(", parts: 2)
    [body, _] = String.split(body, "\n  defp ", parts: 2)
    body
  end

  defp webhook_grenen do
    body = module_content_kroppen()
    [_, gren] = String.split(body, ":webhook ->", parts: 2)
    [gren, _] = String.split(gren, "\n        _ ->", parts: 2)
    gren
  end

  test "provet hittar grenen alls" do
    # Utan den här raden är hela filen grön av att regexen slutat träffa.
    assert module_content_kroppen() =~ ":webhook ->"
  end

  test "VAKT: webhook-grenen bär samma fyra nycklar som :in_app" do
    gren = webhook_grenen()

    for {nyckel, callback} <- [
          {"title", "notification_title"},
          {"message", "notification_message"},
          {"action_url", "action_url"},
          {"action_label", "action_label"}
        ] do
      assert gren =~ "#{nyckel}: module.#{callback}(",
             """
             `:webhook` bygger innehåll utan `#{nyckel}`.

             En modulbaserad händelse kan då inte sätta den — `#{callback}/2`
             anropas aldrig för transporten, och avsändaren har ingen
             möjlighet att upptäcka det utom genom att läsa det som kom fram.
             """
    end
  end

  test "VAKT: extra_content läggs UNDER transportens nycklar" do
    kropp = module_content_kroppen()

    assert kropp =~ "EventResolver.extra_content(",
           "modulens egna nycklar hämtas aldrig"

    # Ordningen ÄR regeln. `Map.merge(extra, transport_content)` låter
    # transporten vinna; kastas de om kan ett tillägg tysta `message`, och då
    # är den tysta ytan tillbaka i en ny form.
    [_, efter] = String.split(kropp, "EventResolver.extra_content(", parts: 2)

    assert efter =~ ~r/Map\.merge\(extra\).*Map\.merge\(transport_content\)/s,
           """
           Tillägget måste slås ihop FÖRE transportens innehåll, så att
           transportens nycklar vinner. Annars kan `extra_content/2` skriva
           över `message` — och den som felsöker letar efter en text som
           `notification_message/2` mycket riktigt returnerade.
           """
  end

  describe "EventResolver.extra_content/3" do
    setup do
      %{
        context: %Context{event_id: "t", data: %{}, metadata: %{}},
        channel: %Channel{transport: :webhook, audience: :slack_kanal}
      }
    end

    test "en modul utan callbacken ger en tom karta", %{context: c, channel: ch} do
      defmodule UtanExtra do
      end

      assert AshDispatch.EventResolver.extra_content(UtanExtra, c, ch) == %{}
    end

    test "modulens karta kommer fram", %{context: c, channel: ch} do
      defmodule MedExtra do
        def extra_content(_c, _ch), do: %{slack_ikon: "avtal", slack_falt: [%{etikett: "A"}]}
      end

      assert AshDispatch.EventResolver.extra_content(MedExtra, c, ch) == %{
               slack_ikon: "avtal",
               slack_falt: [%{etikett: "A"}]
             }
    end

    test "något som inte är en karta ignoreras — en notis som uteblir är dyrare", %{
      context: c,
      channel: ch
    } do
      defmodule FelTypExtra do
        def extra_content(_c, _ch), do: [:inte, :en, :karta]
      end

      assert AshDispatch.EventResolver.extra_content(FelTypExtra, c, ch) == %{}
    end

    @tag :capture_log
    test "en callback som kastar fäller inte dispatchen", %{context: c, channel: ch} do
      defmodule KastandeExtra do
        def extra_content(_c, _ch), do: raise("boom")
      end

      assert AshDispatch.EventResolver.extra_content(KastandeExtra, c, ch) == %{}
    end
  end
end
