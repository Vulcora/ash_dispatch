defmodule AshDispatch.Plugs.ResendWebhookTest do
  @moduledoc """
  The ready webhook endpoint, and that it cannot be configured into
  fail-open.

  `verify/4` has existed since 0.5.4 and `process_webhook/2` for longer;
  BACKLOG 4 said the plug that puts them together was still open. Four hosts
  wrote it, **one of them fail-open**, with a router that announced "verified
  by provider-specific signatures" while verifying nothing. This file's job is
  mostly to prove the refusals: an unverified request must reach no query, and
  the answers must tell a stranger nothing.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias AshDispatch.Plugs.RawBodyReader
  alias AshDispatch.Plugs.ResendWebhook
  alias AshDispatch.Test.DeliveryReceipt

  @moduletag :capture_log

  @secret_key :crypto.strong_rand_bytes(24)
  @secret "whsec_" <> Base.encode64(@secret_key)

  setup do
    Application.put_env(:ash_dispatch, :delivery_receipt_resource, DeliveryReceipt)
    on_exit(fn -> Application.delete_env(:ash_dispatch, :delivery_receipt_resource) end)
    :ok
  end

  defp sign(body, id, ts, key \\ @secret_key) do
    "v1," <> Base.encode64(:crypto.mac(:hmac, :sha256, key, "#{id}.#{ts}.#{body}"))
  end

  defp request(body, opts \\ []) do
    id = Keyword.get(opts, :id, "msg_1")
    ts = Keyword.get(opts, :ts, to_string(System.system_time(:second)))

    conn =
      conn(:post, Keyword.get(opts, :path, "/webhooks/resend"), body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("svix-id", id)
      |> put_req_header("svix-timestamp", ts)
      |> put_req_header("svix-signature", Keyword.get(opts, :sig, sign(body, id, ts)))

    # As an endpoint with the body reader in front of it: the raw body kept,
    # and the params parsed.
    if Keyword.get(opts, :reader?, true) do
      {:ok, raw, conn} = RawBodyReader.read_body(conn, [])
      %{conn | params: Jason.decode!(raw), body_params: Jason.decode!(raw)}
    else
      conn
    end
  end

  defp receipt!(provider_id) do
    DeliveryReceipt
    |> Ash.Changeset.for_create(:create, %{
      event_id: "orders.created",
      transport: :email,
      recipient: "user@example.com",
      provider_id: provider_id,
      status: :sent
    })
    |> Ash.create!(authorize?: false)
  end

  defp payload(email_id, type \\ "email.opened") do
    Jason.encode!(%{
      "type" => type,
      "created_at" => "2026-11-22T09:00:00.000Z",
      "data" => %{"email_id" => email_id}
    })
  end

  describe "a verified webhook" do
    test "updates the receipt and answers 200" do
      receipt = receipt!("prov-1")
      body = payload("prov-1")

      conn = ResendWebhook.call(request(body), secret: @secret)

      assert conn.status == 200
      assert conn.resp_body == "ok"
      assert conn.halted

      assert Ash.get!(DeliveryReceipt, receipt.id, authorize?: false).opened_at
    end

    test "about a message this host never sent answers 200, so the provider stops" do
      body = payload("prov-nobody-has")

      conn = ResendWebhook.call(request(body), secret: @secret)

      # A 4xx here would have the provider retrying a message we have no row
      # for until it gave up.
      assert conn.status == 200
    end

    test "with a payload that is not a Resend event answers 400" do
      body = Jason.encode!(%{"hello" => "world"})

      conn = ResendWebhook.call(request(body), secret: @secret)

      assert conn.status == 400
    end
  end

  describe "it cannot be configured into fail-open" do
    test "no secret option at all is a 400, not a skipped check" do
      receipt = receipt!("prov-2")

      conn = ResendWebhook.call(request(payload("prov-2")), [])

      assert conn.status == 400
      refute Ash.get!(DeliveryReceipt, receipt.id, authorize?: false).opened_at
    end

    test "a {:system, var} that is unset is a 400" do
      System.delete_env("ASH_DISPATCH_TEST_NO_SUCH_SECRET")

      conn =
        ResendWebhook.call(
          request(payload("prov-3")),
          secret: {:system, "ASH_DISPATCH_TEST_NO_SUCH_SECRET"}
        )

      assert conn.status == 400
    end

    test "an empty secret is a 400" do
      assert ResendWebhook.call(request(payload("x")), secret: "").status == 400
    end

    test "a wrong signature is a 400 and nothing is touched" do
      receipt = receipt!("prov-4")
      body = payload("prov-4")

      conn = ResendWebhook.call(request(body, sig: "v1,AAAA"), secret: @secret)

      assert conn.status == 400
      refute Ash.get!(DeliveryReceipt, receipt.id, authorize?: false).opened_at
    end

    test "a signature over a different body is a 400" do
      body = payload("prov-5")
      tampered = payload("prov-6")

      id = "msg_1"
      ts = to_string(System.system_time(:second))

      conn =
        conn(:post, "/webhooks/resend", tampered)
        |> put_req_header("svix-id", id)
        |> put_req_header("svix-timestamp", ts)
        |> put_req_header("svix-signature", sign(body, id, ts))
        |> then(fn conn ->
          {:ok, raw, conn} = RawBodyReader.read_body(conn, [])
          %{conn | params: Jason.decode!(raw)}
        end)
        |> ResendWebhook.call(secret: @secret)

      assert conn.status == 400
    end

    test "a stale timestamp is a 400" do
      stale = to_string(System.system_time(:second) - 4000)

      conn = ResendWebhook.call(request(payload("x"), ts: stale), secret: @secret)

      assert conn.status == 400
    end

    test "missing svix headers are a 400" do
      conn =
        conn(:post, "/webhooks/resend", payload("x"))
        |> then(fn conn ->
          {:ok, raw, conn} = RawBodyReader.read_body(conn, [])
          %{conn | params: Jason.decode!(raw)}
        end)
        |> ResendWebhook.call(secret: @secret)

      assert conn.status == 400
    end

    test "a body already consumed without the reader is a 400, not a degraded mode" do
      receipt = receipt!("prov-7")
      body = payload("prov-7")
      id = "msg_1"
      ts = to_string(System.system_time(:second))

      conn =
        conn(:post, "/webhooks/resend", body)
        |> put_req_header("svix-id", id)
        |> put_req_header("svix-timestamp", ts)
        |> put_req_header("svix-signature", sign(body, id, ts))
        # A parser read the body and kept nothing: `read_body` now answers "".
        |> then(fn conn ->
          {:ok, _raw, conn} = Plug.Conn.read_body(conn, [])
          %{conn | params: Jason.decode!(body)}
        end)
        |> ResendWebhook.call(secret: @secret)

      assert conn.status == 400
      refute Ash.get!(DeliveryReceipt, receipt.id, authorize?: false).opened_at
    end
  end

  describe "what the answers say" do
    test "never a reason — the endpoint is reachable by strangers" do
      bodies = [
        {request(payload("prov-unknown")), [secret: @secret]},
        {request(payload("x"), sig: "v1,AAAA"), [secret: @secret]},
        {request(payload("x")), []}
      ]

      for {conn, opts} <- bodies do
        answered = ResendWebhook.call(conn, opts)

        assert answered.resp_body in ["ok", "error"]
        refute answered.resp_body =~ "tenant"
        refute answered.resp_body =~ "secret"
        refute answered.resp_body =~ "signature"
      end
    end
  end

  describe "the tenant" do
    test "a path param is passed to the handler" do
      receipt = receipt!("prov-8")
      body = payload("prov-8")

      conn =
        request(body)
        |> then(fn conn -> %{conn | params: Map.put(conn.params, "tenant", "acme")} end)
        |> ResendWebhook.call(secret: @secret, tenant: {:path_param, "tenant"})

      # This receipt resource declares no multitenancy, so the library never
      # mentions a tenant to it (`AshDispatch.Tenancy`) and the lookup is the
      # one it would have done without the option. The path param reaching the
      # handler is what is pinned here; `test/tenancy/webhook_trust_test.exs`
      # is where a named tenant is held against `tenants:`.
      assert conn.status == 200
      assert Ash.get!(DeliveryReceipt, receipt.id, authorize?: false).opened_at
    end

    test "no tenant option means no tenant, which is right for public receipts" do
      receipt = receipt!("prov-9")

      conn = ResendWebhook.call(request(payload("prov-9")), secret: @secret)

      assert conn.status == 200
      assert Ash.get!(DeliveryReceipt, receipt.id, authorize?: false).opened_at
    end

    test "an {m, f, a} source is called with the conn" do
      receipt = receipt!("prov-10")

      conn =
        ResendWebhook.call(
          request(payload("prov-10")),
          secret: @secret,
          tenant: {__MODULE__, :no_tenant, []}
        )

      assert conn.status == 200
      assert Ash.get!(DeliveryReceipt, receipt.id, authorize?: false).opened_at
    end

    test "a tenant source that is neither is ignored rather than guessed at" do
      receipt = receipt!("prov-11")

      conn =
        ResendWebhook.call(request(payload("prov-11")), secret: @secret, tenant: "a string")

      assert conn.status == 200
      assert Ash.get!(DeliveryReceipt, receipt.id, authorize?: false).opened_at
    end
  end

  describe "init/1" do
    test "keeps the options, so a router can pass them" do
      assert ResendWebhook.init(secret: "x") == [secret: "x"]
    end
  end

  @doc false
  def no_tenant(_conn), do: nil
end
