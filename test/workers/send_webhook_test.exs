defmodule AshDispatch.Workers.SendWebhookTest do
  @moduledoc """
  Kroppsvalet i webhook-workern.

  The rule exists for signed webhooks: the signature is computed over the body
  BEFORE it is sent, so what is sent must be the same bytes. Let the HTTP
  client re-encode a map and key order and float formatting can change, and the
  signature fails intermittently — which is worse than always.
  """

  use ExUnit.Case, async: true

  alias AshDispatch.Workers.SendWebhook

  test "raw_body skickas verbatim" do
    kropp = ~s({"b":2,"a":1})
    assert SendWebhook.body_option(%{"raw_body" => kropp}) == [body: kropp]
  end

  test "raw_body wins over payload — otherwise we sign different bytes than we send" do
    assert SendWebhook.body_option(%{"raw_body" => "raw", "payload" => %{"a" => 1}}) ==
             [body: "raw"]
  end

  # Backwards compatibility: the Discord and Slack transports send no raw_body
  # and must behave exactly as before.
  test "utan raw_body kodas payload som JSON, som tidigare" do
    assert SendWebhook.body_option(%{"payload" => %{"a" => 1}}) == [json: %{"a" => 1}]
    assert SendWebhook.body_option(%{}) == [json: nil]
  end

  test "a non-binary raw_body is ignored rather than sent as junk" do
    assert SendWebhook.body_option(%{"raw_body" => %{"a" => 1}, "payload" => %{"b" => 2}}) ==
             [json: %{"b" => 2}]
  end

  describe "permanent?/1 — what is worth resending" do
    test "4xx is permanent: the same request gives the same answer" do
      for status <- [400, 401, 403, 404, 410, 422] do
        assert SendWebhook.permanent?(%{status: status}), "#{status} borde vara permanent"
      end
    end

    # The two 4xx codes that are about TIME rather than content.
    test "408 and 429 are not permanent — they mean again and later" do
      refute SendWebhook.permanent?(%{status: 408})
      refute SendWebhook.permanent?(%{status: 429})
    end

    test "5xx and network errors are retryable — they say not now, not never" do
      for status <- [500, 502, 503, 504] do
        refute SendWebhook.permanent?(%{status: status})
      end

      refute SendWebhook.permanent?(%Mint.TransportError{reason: :closed})
      refute SendWebhook.permanent?(:timeout)
      refute SendWebhook.permanent?(%{reason: "something else"})
    end
  end
end
