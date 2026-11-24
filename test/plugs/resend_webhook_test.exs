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

    test ~s(with "data": null answers the documented 400, not a 500) do
      # `"data": null` matched the clause that destructures `"data"` — the key
      # IS there — and then `Map.get(nil, "email_id")` raised: a 500 and a
      # stacktrace out of an endpoint a stranger can reach.
      body =
        Jason.encode!(%{
          "type" => "email.opened",
          "created_at" => "2026-11-22T09:00:00.000Z",
          "data" => nil
        })

      conn = ResendWebhook.call(request(body), secret: @secret)

      assert conn.status == 400
      assert conn.resp_body == "error"
    end

    test ~s(and so does a "data" that is a list) do
      body = Jason.encode!(%{"type" => "email.opened", "data" => []})

      assert ResendWebhook.call(request(body), secret: @secret).status == 400
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

  describe "it acts on the VERIFIED body, not on conn.params" do
    test "a conn.params that disagrees with the signed body is ignored" do
      # The signature covers the bytes. Acting on `conn.params` means acting
      # on whatever the parsers merged together — and a parser earlier in the
      # pipeline merging query-string or path params into it is ordinary
      # Phoenix, not an attack.
      receipt = receipt!("prov-signed")
      body = payload("prov-signed")

      conn =
        request(body)
        |> then(fn conn ->
          %{conn | params: %{"type" => "email.bounced", "data" => %{"email_id" => "prov-other"}}}
        end)
        |> ResendWebhook.call(secret: @secret)

      assert conn.status == 200

      stored = Ash.get!(DeliveryReceipt, receipt.id, authorize?: false)

      # The SIGNED body said opened, about this receipt.
      assert stored.opened_at
      refute stored.bounced_at
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
        |> then(fn conn -> %{conn | path_params: %{"tenant" => "acme"}} end)
        |> ResendWebhook.call(secret: @secret, tenant: {:path_param, "tenant"})

      # This receipt resource declares no multitenancy, so the library never
      # mentions a tenant to it (`AshDispatch.Tenancy`) and the lookup is the
      # one it would have done without the option. The path param reaching the
      # handler is what is pinned here; `test/tenancy/webhook_trust_test.exs`
      # is where a named tenant is held against `tenants:`.
      assert conn.status == 200
      assert Ash.get!(DeliveryReceipt, receipt.id, authorize?: false).opened_at
    end

    test "it is read from path_params, NOT from the body" do
      # `conn.params` is whatever the parsers merged together, so a body key
      # called "tenant" could otherwise name the schema to look in.
      receipt = receipt!("prov-8b")

      body =
        Jason.encode!(%{
          "type" => "email.opened",
          "created_at" => "2026-11-22T09:00:00.000Z",
          "data" => %{"email_id" => "prov-8b"},
          "tenant" => "chosen_by_the_sender"
        })

      conn =
        request(body)
        |> then(fn conn -> %{conn | path_params: %{"tenant" => "acme"}} end)
        |> ResendWebhook.call(secret: @secret, tenant: {:path_param, "tenant"})

      assert conn.status == 200
      assert Ash.get!(DeliveryReceipt, receipt.id, authorize?: false).opened_at
    end

    test "a configured path param that is missing is a 400, not a cheerful 200" do
      # A typo'd route, a router change. Degrading to "no tenant" meant the
      # lookup ran in the wrong schema, found nothing, and told the provider
      # everything was fine — for ever.
      receipt = receipt!("prov-8c")

      conn =
        ResendWebhook.call(
          request(payload("prov-8c")),
          secret: @secret,
          tenant: {:path_param, "tenant"}
        )

      assert conn.status == 400
      refute Ash.get!(DeliveryReceipt, receipt.id, authorize?: false).opened_at
    end

    test "an {m, f, a} that yields nothing is a 400 too" do
      conn =
        ResendWebhook.call(
          request(payload("prov-8d")),
          secret: @secret,
          tenant: {__MODULE__, :no_tenant, []}
        )

      assert conn.status == 400
    end

    test "a tenant resolver that raises answers the plain 400, not a 500" do
      conn =
        ResendWebhook.call(
          request(payload("prov-8e")),
          secret: @secret,
          tenant: {__MODULE__, :raising_tenant, []}
        )

      assert conn.status == 400
      assert conn.resp_body == "error"
    end

    test "a secret {m, f, a} that raises answers the plain 400 as well" do
      conn =
        ResendWebhook.call(
          request(payload("prov-8f")),
          secret: {__MODULE__, :raising_secret, []}
        )

      assert conn.status == 400
      assert conn.resp_body == "error"
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
          tenant: {__MODULE__, :conn_tenant, []}
        )

      assert conn.status == 200
      assert_received {:tenant_asked, %Plug.Conn{}}
      assert Ash.get!(DeliveryReceipt, receipt.id, authorize?: false).opened_at
    end

    test ":tag with a tag in the payload goes through" do
      put_tenant_tag_on()
      put_per_tenant_receipts()

      body =
        Jason.encode!(%{
          "type" => "email.opened",
          "created_at" => "2026-11-22T09:00:00.000Z",
          "data" => %{
            "email_id" => "prov-tag-1",
            "headers" => [%{"name" => "X-AshDispatch-Tenant", "value" => "tenant_a"}]
          }
        })

      conn = ResendWebhook.call(request(body), secret: @secret, tenant: :tag)

      # The tenant was named, so the handler got to look it up. These test
      # receipts are not in that schema, hence "not found" and a 200 — what is
      # pinned here is that it was NOT refused.
      assert conn.status == 200
    end

    test ":tag with NO tag is a 400 when the receipts are per tenant" do
      # The hole round one left open. Resend's opened and clicked events carry
      # no headers at all, and nor does any event about a message sent before
      # the flag was switched on — so this is the common case, not the exotic
      # one. It used to look the id up with no tenant, in the wrong schema,
      # answer "not found", and return 200: every such event lost in silence.
      put_tenant_tag_on()
      put_per_tenant_receipts()

      receipt = receipt!("prov-tag-2")

      conn =
        ResendWebhook.call(request(payload("prov-tag-2")), secret: @secret, tenant: :tag)

      assert conn.status == 400
      assert conn.resp_body == "error"
      refute Ash.get!(DeliveryReceipt, receipt.id, authorize?: false).opened_at
    end

    test ":tag with no tag is fine when the receipts are PUBLIC" do
      # There the tenant names a column, not a schema, and a missing tag costs
      # nothing.
      put_tenant_tag_on()
      receipt = receipt!("prov-tag-3")

      conn =
        ResendWebhook.call(request(payload("prov-tag-3")), secret: @secret, tenant: :tag)

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

    test "warns for per-tenant receipts with no tenant source" do
      # Every webhook would look its message id up in the wrong schema and
      # answer 200 — and at request time that is indistinguishable from an
      # event about a message this host never sent, which is the answer that
      # is SUPPOSED to be a 200. So it has to be said at boot.
      previous = Application.fetch_env(:ash_dispatch, :delivery_receipt_resource)

      Application.put_env(
        :ash_dispatch,
        :delivery_receipt_resource,
        AshDispatch.Test.PerTenant.Receipt
      )

      on_exit(fn ->
        case previous do
          {:ok, old} -> Application.put_env(:ash_dispatch, :delivery_receipt_resource, old)
          :error -> Application.delete_env(:ash_dispatch, :delivery_receipt_resource)
        end
      end)

      assert ExUnit.CaptureIO.capture_io(:stderr, fn ->
               ResendWebhook.init(secret: "x")
             end) =~ "per tenant and no"
    end

    test "and says nothing when a source is configured" do
      previous = Application.fetch_env(:ash_dispatch, :delivery_receipt_resource)

      Application.put_env(
        :ash_dispatch,
        :delivery_receipt_resource,
        AshDispatch.Test.PerTenant.Receipt
      )

      on_exit(fn ->
        case previous do
          {:ok, old} -> Application.put_env(:ash_dispatch, :delivery_receipt_resource, old)
          :error -> Application.delete_env(:ash_dispatch, :delivery_receipt_resource)
        end
      end)

      assert ExUnit.CaptureIO.capture_io(:stderr, fn ->
               ResendWebhook.init(secret: "x", tenant: {:path_param, "tenant"})
             end) == ""
    end

    test "and nothing for public receipts" do
      assert ExUnit.CaptureIO.capture_io(:stderr, fn ->
               ResendWebhook.init(secret: "x")
             end) == ""
    end
  end

  defp put_tenant_tag_on do
    previous = Application.fetch_env(:ash_dispatch, :webhook_tenant_tag)
    Application.put_env(:ash_dispatch, :webhook_tenant_tag, true)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:ash_dispatch, :webhook_tenant_tag, old)
        :error -> Application.delete_env(:ash_dispatch, :webhook_tenant_tag)
      end
    end)
  end

  defp put_per_tenant_receipts do
    previous = Application.fetch_env(:ash_dispatch, :delivery_receipt_resource)

    Application.put_env(
      :ash_dispatch,
      :delivery_receipt_resource,
      AshDispatch.Test.PerTenant.Receipt
    )

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:ash_dispatch, :delivery_receipt_resource, old)
        :error -> Application.delete_env(:ash_dispatch, :delivery_receipt_resource)
      end
    end)
  end

  @doc false
  def no_tenant(_conn), do: nil

  @doc false
  def conn_tenant(conn) do
    send(self(), {:tenant_asked, conn})
    "acme"
  end

  @doc false
  def raising_tenant(_conn), do: raise("the tenant resolver is down")

  @doc false
  def raising_secret, do: raise("the vault is down")
end
