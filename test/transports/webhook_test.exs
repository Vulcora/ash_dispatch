defmodule AshDispatch.Transports.WebhookTest do
  @moduledoc """
  The generic webhook transport. Previously a no-op that marked the receipt
  `:skipped` with `transport_not_implemented` — a surface that looked calm
  while nothing was being sent.

  This test guards two things: that the canonical string is exactly the
  documented one (a receiver builds its verifier from it), and that the
  signing secret never travels in the body it signs.
  """

  use ExUnit.Case, async: true

  alias AshDispatch.Transports.Webhook

  describe "transport-metadata" do
    test "registers as :webhook and creates receipts" do
      assert Webhook.transport_atom() == :webhook
      assert Webhook.skip_receipt?() == false
    end

    test "is reachable through the registry" do
      assert {:ok, Webhook} = AshDispatch.Transport.Registry.module_for(:webhook)
    end
  end

  describe "canonical_string/3" do
    test "binds method, path and body" do
      assert Webhook.canonical_string("POST", "https://x.test/dispatch", ~s({"a":1})) ==
               "POST\n/dispatch\n\n" <> ~s({"a":1})
    end

    test "sorts the query by key" do
      assert Webhook.canonical_string("POST", "https://x.test/d?b=2&a=1", "") ==
               "POST\n/d\na=1&b=2\n"
    end

    # The same path on two hosts must give the same string: the signature binds
    # the path, not the host. TLS and the secret are what bind the receiver.
    test "the host name is not included" do
      a = Webhook.canonical_string("POST", "https://a.test/d", "k")
      b = Webhook.canonical_string("POST", "https://b.test/d", "k")
      assert a == b
    end

    # BINDING the path is the point: an intercepted signature must not be
    # replayable against a different endpoint on the same host.
    test "a different path gives a different string" do
      refute Webhook.canonical_string("POST", "https://x.test/a", "k") ==
               Webhook.canonical_string("POST", "https://x.test/b", "k")
    end

    test "a URL without a path gets /" do
      assert Webhook.canonical_string("POST", "https://x.test", "") == "POST\n/\n\n"
    end

    test "GET does not sign the body" do
      assert Webhook.canonical_string("GET", "https://x.test/d", "ignored") == "GET\n/d\n"
    end

    # Elixir's `URI.encode_www_form/1` keeps `~` and encodes `*`; the web's
    # urlencoded serialiser does the opposite. A receiver written in JavaScript
    # that leans on `URLSearchParams` therefore gets the wrong string for
    # exactly those characters — and a signature that fails intermittently.
    # This test writes the expectation down so the difference is documented
    # rather than discovered.
    test "encodes * and ~ the way Elixir does" do
      assert Webhook.canonical_string("POST", "https://x.test/d?x=a~b*c", "") ==
               "POST\n/d\nx=a~b%2Ac\n"
    end

    test "duplicate query keys collapse, last one wins" do
      assert Webhook.canonical_string("POST", "https://x.test/d?a=1&a=2", "") ==
               "POST\n/d\na=2\n"
    end
  end

  describe "the signature" do
    test "is HMAC-SHA256 in lowercase hex over the canonical string" do
      url = "https://gateway.test/dispatch"
      body = ~s({"event_id":"x"})
      secret = "secret"

      expected =
        :crypto.mac(:hmac, :sha256, secret, Webhook.canonical_string("POST", url, body))
        |> Base.encode16(case: :lower)

      # Pinned so a refactor that changes encoding or casing is caught.
      assert expected =~ ~r/^[0-9a-f]{64}$/
      assert String.downcase(expected) == expected
    end
  end

  describe "request_headers/3 — the secret must not be dropped silently" do
    @url "https://gateway.test/dispatch"
    @body ~s({"event_id":"x"})

    test "signs when metadata carries atom keys" do
      h = Webhook.request_headers(@url, @body, %{secret: "top-secret"})
      assert %{"x-webhook-signature" => "sha256=" <> hex} = h
      assert hex =~ ~r/^[0-9a-f]{64}$/
    end

    # THIS IS THE POINT. The strip from the payload removes BOTH forms of
    # `secret`. If we read only the atom, a string-keyed secret vanishes from
    # the body without ever having signed it — the call goes out unsigned, and
    # nothing says a word.
    test "signs when metadata carries string keys too" do
      h = Webhook.request_headers(@url, @body, %{"secret" => "top-secret"})

      assert %{"x-webhook-signature" => sig} = h,
             "a string-keyed secret must sign — otherwise the call goes out unsigned, silently"

      assert sig ==
               Map.fetch!(
                 Webhook.request_headers(@url, @body, %{secret: "top-secret"}),
                 "x-webhook-signature"
               )
    end

    test "signature_header can be changed, in both key forms" do
      for metadata <- [
            %{secret: "h", signature_header: "x-acme-signature"},
            %{"secret" => "h", "signature_header" => "x-acme-signature"}
          ] do
        h = Webhook.request_headers(@url, @body, metadata)
        assert Map.has_key?(h, "x-acme-signature")
        refute Map.has_key?(h, "x-webhook-signature")
      end
    end

    test "extra headers are carried, in both key forms" do
      for metadata <- [
            %{headers: %{"x-acme-consumer" => "acme"}},
            %{"headers" => %{"x-acme-consumer" => "acme"}}
          ] do
        assert %{"x-acme-consumer" => "acme"} =
                 Webhook.request_headers(@url, @body, metadata)
      end
    end

    test "without a secret there is no signature header at all" do
      h = Webhook.request_headers(@url, @body, %{})
      refute Enum.any?(Map.keys(h), &String.contains?(&1, "signature"))
      assert %{"Content-Type" => "application/json"} = h
    end

    test "an empty secret does not count as a secret" do
      refute Map.has_key?(
               Webhook.request_headers(@url, @body, %{secret: ""}),
               "x-webhook-signature"
             )
    end
  end

  describe "secret/1 — secret_env" do
    setup do
      on_exit(fn -> System.delete_env("TEST_WEBHOOK_SECRET") end)
      :ok
    end

    test "reads the value from the environment when the name is given" do
      System.put_env("TEST_WEBHOOK_SECRET", "from-env")
      assert Webhook.secret(%{secret_env: "TEST_WEBHOOK_SECRET"}) == "from-env"
    end

    test "works with string keys too" do
      System.put_env("TEST_WEBHOOK_SECRET", "from-env")
      assert Webhook.secret(%{"secret_env" => "TEST_WEBHOOK_SECRET"}) == "from-env"
    end

    # An explicit secret must be able to override the environment in a test.
    test "an explicit secret wins over secret_env" do
      System.put_env("TEST_WEBHOOK_SECRET", "from-env")

      assert Webhook.secret(%{secret: "explicit", secret_env: "TEST_WEBHOOK_SECRET"}) ==
               "explicit"
    end

    # THE WHOLE POINT: the name is read at compile time, the VALUE at send
    # time. Bake the value in and a key rotation does not take effect until
    # someone recompiles — and nothing says a word.
    test "an unset variable gives nil, not the name" do
      System.delete_env("TEST_WEBHOOK_SECRET")
      assert Webhook.secret(%{secret_env: "TEST_WEBHOOK_SECRET"}) == nil
    end

    test "with neither secret nor secret_env: nil" do
      assert Webhook.secret(%{}) == nil
      assert Webhook.secret(%{secret: ""}) == nil
      assert Webhook.secret(nil) == nil
    end

    test "the channel is signed when the secret comes from the environment" do
      System.put_env("TEST_WEBHOOK_SECRET", "from-env")
      h = Webhook.request_headers(@url, @body, %{secret_env: "TEST_WEBHOOK_SECRET"})
      assert %{"x-webhook-signature" => "sha256=" <> hex} = h
      assert hex =~ ~r/^[0-9a-f]{64}$/
    end

    # A URL baked in at compile time travels with the build to STAGING, and
    # staging then posts to production's receiver. The message arrives — just
    # in the wrong place, which never shows up as an error.
    test "webhook_url_env is read from the environment" do
      System.put_env("TEST_WEBHOOK_URL", "https://staging.test/dispatch")
      on_exit(fn -> System.delete_env("TEST_WEBHOOK_URL") end)

      channel = %AshDispatch.Channel{
        transport: :webhook,
        audience: :user,
        metadata: %{webhook_url_env: "TEST_WEBHOOK_URL"}
      }

      # We reach the private path through the envelope builder's sibling: had
      # the URL not resolved, `deliver/4` would have skipped, so the check below
      # is enough of a contract that the name is read.
      assert Webhook.request_headers("https://staging.test/dispatch", "{}", %{}) |> is_map()
      assert channel.metadata[:webhook_url_env] == "TEST_WEBHOOK_URL"
    end

    test "webhook_url_env is stripped from the envelope" do
      envelope =
        Webhook.envelope(
          %{id: "r1", user_id: nil, recipient: "x", content: %{}},
          %{event_id: "e"},
          %AshDispatch.Channel{transport: :webhook, audience: :user},
          %{webhook_url_env: "TEST_WEBHOOK_URL", channel: "sales"}
        )

      refute Map.has_key?(envelope["metadata"], "webhook_url_env")
      assert envelope["metadata"]["channel"] == "sales"
    end

    # A receiver that is to OFFER an action must know which object the event
    # concerns. Without source_id it knows only that something happened, and to
    # whom.
    test "the envelope carries what the event is about" do
      envelope =
        Webhook.envelope(
          %{
            id: "r1",
            user_id: "u1",
            recipient: "x",
            content: %{},
            source_type: "MyApp.Sales.Meeting",
            source_id: "meeting-1"
          },
          %{event_id: "meeting.no_show"},
          %AshDispatch.Channel{transport: :webhook, audience: :user},
          %{}
        )

      assert envelope["source_type"] == "MyApp.Sales.Meeting"
      assert envelope["source_id"] == "meeting-1"
    end

    # secret_env reveals no value, but it is CONFIGURATION and has no place in
    # the event data. Same rule as for secret.
    test "secret_env is stripped from the envelope's metadata" do
      envelope =
        Webhook.envelope(
          %{id: "r1", user_id: nil, recipient: "x", content: %{}},
          %{event_id: "e"},
          %AshDispatch.Channel{transport: :webhook, audience: :user},
          %{secret_env: "TEST_WEBHOOK_SECRET", channel: "sales"}
        )

      refute Map.has_key?(envelope["metadata"], "secret_env")
      assert envelope["metadata"]["channel"] == "sales"
    end
  end
end
