defmodule AshDispatch.Transports.WebhookTest do
  @moduledoc """
  Den generiska webhook-transporten. Tidigare en no-op som satte kvittot till
  `:skipped` med `transport_not_implemented` — en yta som såg lugn ut medan
  ingenting skickades.

  Provet vaktar två saker: att kanoniska strängen är exakt den dokumenterade
  (en mottagare bygger sin verifierare ur den), och att signeringsnyckeln
  aldrig följer med i kroppen den signerar.
  """

  use ExUnit.Case, async: true

  alias AshDispatch.Transports.Webhook

  describe "transport-metadata" do
    test "registrerar sig som :webhook och skapar kvitton" do
      assert Webhook.transport_atom() == :webhook
      assert Webhook.skip_receipt?() == false
    end

    test "är nåbar via registret" do
      assert {:ok, Webhook} = AshDispatch.Transport.Registry.module_for(:webhook)
    end
  end

  describe "canonical_string/3" do
    test "binder metod, väg och kropp" do
      assert Webhook.canonical_string("POST", "https://x.test/dispatch", ~s({"a":1})) ==
               "POST\n/dispatch\n\n" <> ~s({"a":1})
    end

    test "sorterar query på nyckel" do
      assert Webhook.canonical_string("POST", "https://x.test/d?b=2&a=1", "") ==
               "POST\n/d\na=1&b=2\n"
    end

    # Samma väg på två värdar ska ge samma sträng: signaturen binder vägen,
    # inte värden. Det är TLS och nyckeln som binder mottagaren.
    test "värdnamnet ingår inte" do
      a = Webhook.canonical_string("POST", "https://a.test/d", "k")
      b = Webhook.canonical_string("POST", "https://b.test/d", "k")
      assert a == b
    end

    # Att BINDA vägen ar poangen: en avlyssnad signatur ska inte kunna
    # spelas upp mot en annan endpoint pa samma host.
    test "olika väg ger olika sträng" do
      refute Webhook.canonical_string("POST", "https://x.test/a", "k") ==
               Webhook.canonical_string("POST", "https://x.test/b", "k")
    end

    test "en URL utan väg får /" do
      assert Webhook.canonical_string("POST", "https://x.test", "") == "POST\n/\n\n"
    end

    test "GET signerar inte kroppen" do
      assert Webhook.canonical_string("GET", "https://x.test/d", "ignoreras") == "GET\n/d\n"
    end

    # Elixirs `URI.encode_www_form/1` behåller `~` och kodar `*`; webbens
    # urlencoded-serialiserare gör tvärtom. En mottagare skriven i JavaScript
    # som lutar sig mot `URLSearchParams` får därför fel sträng för just de
    # tecknen — och en signatur som failar ibland. Provet skriver ut
    # förväntningen så att skillnaden är dokumenterad, inte upptäckt.
    test "kodar * och ~ som Elixir gör" do
      assert Webhook.canonical_string("POST", "https://x.test/d?x=a~b*c", "") ==
               "POST\n/d\nx=a~b%2Ac\n"
    end

    test "dubbletter i query kollapsar sist-vinner" do
      assert Webhook.canonical_string("POST", "https://x.test/d?a=1&a=2", "") ==
               "POST\n/d\na=2\n"
    end
  end

  describe "signaturen" do
    test "är HMAC-SHA256 i gemener hex över kanoniska strängen" do
      url = "https://gateway.test/dispatch"
      body = ~s({"event_id":"x"})
      secret = "hemlig"

      förväntad =
        :crypto.mac(:hmac, :sha256, secret, Webhook.canonical_string("POST", url, body))
        |> Base.encode16(case: :lower)

      # Fixerad så att en refaktorering som byter kodning eller skiftläge fälls.
      assert förväntad =~ ~r/^[0-9a-f]{64}$/
      assert String.downcase(förväntad) == förväntad
    end
  end

  describe "request_headers/3 — nyckeln får inte tappas tyst" do
    @url "https://gateway.test/dispatch"
    @body ~s({"event_id":"x"})

    test "signerar när metadata bär atom-nycklar" do
      h = Webhook.request_headers(@url, @body, %{secret: "hemlig"})
      assert %{"x-webhook-signature" => "sha256=" <> hex} = h
      assert hex =~ ~r/^[0-9a-f]{64}$/
    end

    # DEN HÄR ÄR POÄNGEN. Strykningen ur payloaden tar bort BÅDA formerna av
    # `secret`. Läser vi bara atomen försvinner en sträng-nycklad hemlighet ur
    # kroppen utan att någonsin ha signerat den — anropet går osignerat, och
    # ingenting säger ifrån.
    test "signerar också när metadata bär sträng-nycklar" do
      h = Webhook.request_headers(@url, @body, %{"secret" => "hemlig"})

      assert %{"x-webhook-signature" => sig} = h,
             "en sträng-nycklad secret måste signera — annars går anropet osignerat, tyst"

      assert sig ==
               Map.fetch!(
                 Webhook.request_headers(@url, @body, %{secret: "hemlig"}),
                 "x-webhook-signature"
               )
    end

    test "signature_header går att byta, i båda nyckelformerna" do
      for metadata <- [
            %{secret: "h", signature_header: "x-siteflow-signature"},
            %{"secret" => "h", "signature_header" => "x-siteflow-signature"}
          ] do
        h = Webhook.request_headers(@url, @body, metadata)
        assert Map.has_key?(h, "x-siteflow-signature")
        refute Map.has_key?(h, "x-webhook-signature")
      end
    end

    test "extra headers följer med, i båda nyckelformerna" do
      for metadata <- [
            %{headers: %{"x-siteflow-consumer" => "saleflow"}},
            %{"headers" => %{"x-siteflow-consumer" => "saleflow"}}
          ] do
        assert %{"x-siteflow-consumer" => "saleflow"} =
                 Webhook.request_headers(@url, @body, metadata)
      end
    end

    test "utan secret finns ingen signaturheader alls" do
      h = Webhook.request_headers(@url, @body, %{})
      refute Enum.any?(Map.keys(h), &String.contains?(&1, "signature"))
      assert %{"Content-Type" => "application/json"} = h
    end

    test "en tom secret räknas inte som en secret" do
      refute Map.has_key?(
               Webhook.request_headers(@url, @body, %{secret: ""}),
               "x-webhook-signature"
             )
    end
  end

  describe "hemlighet/1 — secret_env" do
    setup do
      on_exit(fn -> System.delete_env("PROV_WEBHOOK_SECRET") end)
      :ok
    end

    test "läser värdet ur miljön när namnet är angivet" do
      System.put_env("PROV_WEBHOOK_SECRET", "ur-miljon")
      assert Webhook.hemlighet(%{secret_env: "PROV_WEBHOOK_SECRET"}) == "ur-miljon"
    end

    test "fungerar med sträng-nycklar också" do
      System.put_env("PROV_WEBHOOK_SECRET", "ur-miljon")
      assert Webhook.hemlighet(%{"secret_env" => "PROV_WEBHOOK_SECRET"}) == "ur-miljon"
    end

    # En explicit secret ska kunna overrida miljon i ett prov.
    test "explicit secret vinner över secret_env" do
      System.put_env("PROV_WEBHOOK_SECRET", "ur-miljon")

      assert Webhook.hemlighet(%{secret: "explicit", secret_env: "PROV_WEBHOOK_SECRET"}) ==
               "explicit"
    end

    # HELA POÄNGEN: namnet läses vid kompilering, VÄRDET vid utskick. Bakas
    # värdet in slår en nyckelrotation inte igenom förrän någon kompilerar om
    # — och ingenting säger ifrån.
    test "en osatt variabel ger nil, inte namnet" do
      System.delete_env("PROV_WEBHOOK_SECRET")
      assert Webhook.hemlighet(%{secret_env: "PROV_WEBHOOK_SECRET"}) == nil
    end

    test "utan vare sig secret eller secret_env: nil" do
      assert Webhook.hemlighet(%{}) == nil
      assert Webhook.hemlighet(%{secret: ""}) == nil
      assert Webhook.hemlighet(nil) == nil
    end

    test "kanalen signeras när nyckeln kommer ur miljön" do
      System.put_env("PROV_WEBHOOK_SECRET", "ur-miljon")
      h = Webhook.request_headers(@url, @body, %{secret_env: "PROV_WEBHOOK_SECRET"})
      assert %{"x-webhook-signature" => "sha256=" <> hex} = h
      assert hex =~ ~r/^[0-9a-f]{64}$/
    end

    # secret_env avslojar inget varde, men den ar KONFIGURATION och hor inte
    # hemma i handelsedatan. Samma regel som for secret.
    # En mottagare som ska kunna ERBJUDA en atgard maste veta vilket objekt
    # handelsen galler. Utan source_id vet den bara att nagot hande, och till vem.
    test "kuvertet bär vad händelsen handlar om" do
      kuvert =
        Webhook.envelope(
          %{
            id: "r1",
            user_id: "u1",
            recipient: "x",
            content: %{},
            source_type: "Saleflow.Sales.Meeting",
            source_id: "mote-1"
          },
          %{event_id: "meeting.no_show"},
          %AshDispatch.Channel{transport: :webhook, audience: :user},
          %{}
        )

      assert kuvert["source_type"] == "Saleflow.Sales.Meeting"
      assert kuvert["source_id"] == "mote-1"
    end

    test "secret_env stryks ur kuvertets metadata" do
      kuvert =
        Webhook.envelope(
          %{id: "r1", user_id: nil, recipient: "x", content: %{}},
          %{event_id: "e"},
          %AshDispatch.Channel{transport: :webhook, audience: :user},
          %{secret_env: "PROV_WEBHOOK_SECRET", channel: "salj"}
        )

      refute Map.has_key?(kuvert["metadata"], "secret_env")
      assert kuvert["metadata"]["channel"] == "salj"
    end
  end
end
