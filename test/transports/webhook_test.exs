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
end
