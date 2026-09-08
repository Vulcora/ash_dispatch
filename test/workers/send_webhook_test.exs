defmodule AshDispatch.Workers.SendWebhookTest do
  @moduledoc """
  Kroppsvalet i webhook-workern.

  Regeln finns för signerade webhooks: signaturen räknas över kroppen INNAN
  den skickas, så det som skickas måste vara samma bytes. Låter man
  HTTP-klienten koda om en map kan nyckelordning och flyttalsformat ändras,
  och signaturen failar ibland — vilket är värre än alltid.
  """

  use ExUnit.Case, async: true

  alias AshDispatch.Workers.SendWebhook

  test "raw_body skickas verbatim" do
    kropp = ~s({"b":2,"a":1})
    assert SendWebhook.body_option(%{"raw_body" => kropp}) == [body: kropp]
  end

  test "raw_body vinner över payload — annars signerar vi andra bytes än vi sänder" do
    assert SendWebhook.body_option(%{"raw_body" => "rå", "payload" => %{"a" => 1}}) ==
             [body: "rå"]
  end

  # Bakåtkompatibiliteten: Discord- och Slack-transporterna skickar ingen
  # raw_body och ska bete sig exakt som förr.
  test "utan raw_body kodas payload som JSON, som tidigare" do
    assert SendWebhook.body_option(%{"payload" => %{"a" => 1}}) == [json: %{"a" => 1}]
    assert SendWebhook.body_option(%{}) == [json: nil]
  end

  test "en icke-binär raw_body ignoreras i stället för att sändas som skräp" do
    assert SendWebhook.body_option(%{"raw_body" => %{"a" => 1}, "payload" => %{"b" => 2}}) ==
             [json: %{"b" => 2}]
  end

  describe "permanent?/1 — vad som är lönt att skicka om" do
    test "4xx är permanent: samma request ger samma svar" do
      for status <- [400, 401, 403, 404, 410, 422] do
        assert SendWebhook.permanent?(%{status: status}), "#{status} borde vara permanent"
      end
    end

    # De två 4xx som handlar om TID och inte om innehåll.
    test "408 och 429 är inte permanenta — de betyder igen respektive senare" do
      refute SendWebhook.permanent?(%{status: 408})
      refute SendWebhook.permanent?(%{status: 429})
    end

    test "5xx och nätverksfel är retrybara — de säger inte nu, inte inte någonsin" do
      for status <- [500, 502, 503, 504] do
        refute SendWebhook.permanent?(%{status: status})
      end

      refute SendWebhook.permanent?(%Mint.TransportError{reason: :closed})
      refute SendWebhook.permanent?(:timeout)
      refute SendWebhook.permanent?(%{reason: "något annat"})
    end
  end
end
