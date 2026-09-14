defmodule AshDispatch.Transports.InlineContentTextTest do
  @moduledoc """
  Varje transport som BÄR en text måste också LÄSA den ur DSL:en.

  ## Felet vakten finns för

  `build_inline_content/4`:s `:webhook`-gren byggde bara `payload` och
  `webhook_url`. Den läste aldrig `content_config[:message]` — den enda av
  sex grenar som inte gjorde det.

  Följden var tyst, och det är hela poängen. Ett event MED en eventmodul
  faller tillbaka på modulens `notification_message/2`, vars genererade
  default är `"You have a new notification"`. Merge-ordningen i
  `build_content/5` låter modulens värde stå kvar för varje nyckel inline
  inte sätter, så en deklarerad `content: [message: ...]` blev dekoration
  och mottagaren fick platshållaren — med rätt form och fel innehåll.

  Mätt hos en konsument innan fixen: **41 av 41** levererade
  webhook-kvitton bar platshållaren, fördelade på nio deklarerade kanaler.
  Ingen av texterna hade någonsin nått fram. Att den ena halvan var
  kanalposter och den andra personliga DM gjorde ingen skillnad; det var
  transporten, inte eventet.

  ## Varför provet läser källan

  Dispatchen har ingen lättviktig harness här — samma skäl som
  `push_test.exs` skriver ut. Men ett STRUKTURELLT prov som bara frågar
  "finns grenen?" var precis vad som fanns, och det såg en gren som bar fel
  innehåll som en gren som fanns. Vakten frågar därför vad grenen GÖR.
  """

  use ExUnit.Case, async: true

  @dispatcher File.read!("lib/dispatcher.ex")

  # Transporter vars innehåll ÄR en text. `:email` står utanför med flit:
  # den bär `subject` + `html_body` + `text_body` och har ingen `message`.
  @textbarande [":in_app", ":discord", ":slack", ":sms", ":webhook", ":push"]

  defp grenar do
    [_, body] = String.split(@dispatcher, "defp build_inline_content(", parts: 2)
    [body, _] = String.split(body, "\n  defp ", parts: 2)

    # Dela på grenhuvudena så varje transport prövas för sig. Ett prov som
    # läste hela kroppen hade varit grönt så länge NÅGON gren läste texten.
    Regex.split(~r/^\s{8}(?=:[a-z_]+ ->)/m, body, trim: true)
    |> Enum.map(fn del ->
      case Regex.run(~r/^\s*(:[a-z_]+) ->/, del) do
        [_, namn] -> {namn, del}
        _ -> {nil, del}
      end
    end)
    |> Enum.filter(fn {namn, _} -> namn != nil end)
    |> Map.new()
  end

  test "provet hittar grenarna alls" do
    # Utan den här raden är hela filen grön av att regexen slutat träffa.
    funna = Map.keys(grenar())
    assert length(funna) >= 6, "hittade bara #{inspect(funna)}"
    for t <- @textbarande, do: assert(Map.has_key?(grenar(), t), "grenen #{t} saknas")
  end

  test "VAKT: varje textbärande transport läser content_config[:message]" do
    g = grenar()

    utan =
      Enum.filter(@textbarande, fn t ->
        not (g[t] =~ "content_config[:message]")
      end)

    assert utan == [],
           """
           Dessa transportgrenar bygger innehåll utan att läsa texten ur DSL:en:

             #{Enum.join(utan, ", ")}

           En `content: [message: ...]` på en sådan kanal blir DEKORATION. Har
           eventet en modul skickas i stället `notification_message/2`:s
           genererade default — "You have a new notification" — och mottagaren
           kan inte skilja den från en riktig text.

           Lägg till i grenen:

               |> maybe_put(
                 :message,
                 interpolate(
                   content_config[:message] || content_config[:notification_message],
                   context
                 )
               )
           """
  end

  test "VAKT: texten sätts med maybe_put, aldrig som en ovillkorlig nyckel" do
    # `interpolate(nil, _)` ger `nil`. En literal `message:` i map-syntax
    # skriver därför `nil` över modulens callback-text i hybridläget — samma
    # klass som buggen ovan, fast åt andra hållet.
    g = grenar()

    fel =
      Enum.filter(@textbarande, fn t ->
        Regex.match?(~r/^\s*message:\s/m, g[t])
      end)

    assert fel == [],
           """
           Dessa grenar sätter `message:` ovillkorligt:

             #{Enum.join(fel, ", ")}

           Saknas texten i DSL:en blir värdet `nil`, och `Map.merge` i
           `build_content/5` skriver då över modulens callback med ingenting.
           Använd `maybe_put/3`, som hoppar nil.
           """
  end

  test "webhook bär också rubriken — en mottagare som renderar ett kort behöver den" do
    assert grenar()[":webhook"] =~ "content_config[:title]"
  end

  test "webhook behåller payload och url" do
    # Fixen får inte ha tappat det grenen redan gjorde.
    g = grenar()[":webhook"]
    assert g =~ "content_config[:webhook_payload]"
    assert g =~ "channel.webhook_url"
  end

  # Transporter vars mottagare kan RENDERA en väg vidare. `:discord`,
  # `:slack` och `:sms` står utanför med flit: deras nyttolaster har ingen
  # egen knappform, och en url utan en yta som visar den är en nyckel som
  # bara ser ut att göra något.
  @vagbarande [":in_app", ":webhook", ":push"]

  test "VAKT: varje transport med en väg vidare läser content_config[:action_url]" do
    g = grenar()

    utan = Enum.filter(@vagbarande, fn t -> not (g[t] =~ "content_config[:action_url]") end)

    assert utan == [],
           """
           Dessa grenar bygger innehåll utan att läsa vägen vidare ur DSL:en:

             #{Enum.join(utan, ", ")}

           En deklarerad `action_url:` blir då DEKORATION: mottagaren får veta
           att något hänt men har ingen väg dit, och avsändaren kan inte
           upptäcka det utom genom att läsa det som kom fram. `:webhook` var
           precis det fallet till 0.7.3 — en konsument rapporterade sina
           kanalposter som "döda notiser".
           """
  end

  test "webhook bär också knappens etikett — en url utan ord blir en knapp som heter \"Öppna\"" do
    assert grenar()[":webhook"] =~ "content_config[:action_label]"
  end
end
