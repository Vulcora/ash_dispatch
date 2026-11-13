defmodule AshDispatch.Tenancy.WebhookTrustTest do
  @moduledoc """
  What the webhook endpoint may be told, and what it gives back.

  Two properties, both of them about an endpoint that is unauthenticated
  unless the host puts `Resend.verify/3` in front of it:

  - a tenant from the **route** is a value from outside, like a tag. rc.0
    passed `allow_unchecked?: true` for it, so with `:tenants` absent — the
    setup the guide recommends and never said needed `:tenants` — the string
    in `POST /webhooks/resend/:tenant` went straight into a Postgres
    `prefix:`;
  - a refusal does not say whether the tenant exists. rc.0's two refusals were
    distinguishable, so an unauthenticated POST per candidate name enumerated
    the host's schemas, i.e. its customers — and the module's own controller
    example returned `inspect(reason)` in the response body.
  """
  use AshDispatch.Test.PerTenantCase, async: false

  alias AshDispatch.WebhookHandlers.Resend

  @moduletag :postgres
  @moduletag :capture_log

  setup do
    :persistent_term.erase({AshDispatch.Tenants, :warned})
    AshDispatch.Log.forget_throttle({Resend, :not_configured})
    AshDispatch.Log.forget_throttle({Resend, :unknown_tenant})

    on_exit(fn ->
      :persistent_term.erase({AshDispatch.Tenants, :warned})
      AshDispatch.Log.forget_throttle({Resend, :not_configured})
      AshDispatch.Log.forget_throttle({Resend, :unknown_tenant})
    end)

    :ok
  end

  defp sent_receipt!(tenant, provider_id) do
    tenant
    |> receipt!(%{status: :scheduled})
    |> AshDispatch.ReceiptStatus.mark_sent(%{id: provider_id})
  end

  defp opened(provider_id) do
    %{
      "type" => "email.opened",
      "created_at" => "2026-11-12T10:00:00.000Z",
      "data" => %{"email_id" => provider_id}
    }
  end

  defp reload(tenant, id), do: Ash.get!(PerTenant.Receipt, id, authorize?: false, tenant: tenant)

  describe "a route tenant the host cannot check" do
    setup do
      Application.delete_env(:ash_dispatch, :tenants)
      :ok
    end

    test "is refused, and the receipt it named is untouched" do
      receipt = sent_receipt!("tenant_b", "prov-route")

      assert Resend.process_webhook(opened("prov-route"), tenant: "tenant_b") ==
               {:error, :not_found}

      refute reload("tenant_b", receipt.id).opened_at
    end

    test "including a schema name no host would recognise" do
      _receipt = sent_receipt!("tenant_a", "prov-probe")

      assert {:error, :not_found} =
               Resend.process_webhook(opened("prov-probe"), tenant: "pg_catalog")
    end

    test "and the host is told why, once per VM" do
      _receipt = sent_receipt!("tenant_a", "prov-warn")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Resend.process_webhook(opened("prov-warn"), tenant: "tenant_a")
        end)

      assert log =~ ":tenants is not configured"
    end
  end

  describe "the refusals" do
    test "a made-up tenant and a real tenant with no such message answer the same" do
      # `:tenants` is PerTenant.Tenants => tenant_a, tenant_b.
      real = Resend.process_webhook(opened("no-such-id"), tenant: "tenant_a")
      made_up = Resend.process_webhook(opened("no-such-id"), tenant: "tenant_zzz")

      assert real == made_up
      assert real == {:error, :not_found}
    end

    test "and a refused tag answers the same again" do
      Application.put_env(:ash_dispatch, :webhook_tenant_tag, true)
      on_exit(fn -> Application.delete_env(:ash_dispatch, :webhook_tenant_tag) end)

      payload =
        opened("no-such-id")
        |> put_in(["data", "headers"], [
          %{"name" => Resend.tenant_header(), "value" => "tenant_zzz"}
        ])

      assert Resend.process_webhook(payload) == {:error, :not_found}
    end
  end

  describe "the refusal log" do
    test "is a warning, and not one per request" do
      _receipt = sent_receipt!("tenant_a", "prov-flood")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for n <- 1..20 do
            Resend.process_webhook(opened("prov-flood"), tenant: "tenant_#{n}")
          end
        end)

      refute log =~ "[error]"

      assert length(String.split(log, "refusing a tenant this host does not recognise")) == 2,
             "one refusal line for twenty requests, got:\n#{log}"
    end

    test "does not name the tenant the request chose" do
      _receipt = sent_receipt!("tenant_a", "prov-name")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Resend.process_webhook(opened("prov-name"), tenant: "secret-customer-name")
        end)

      refute log =~ "secret-customer-name"
    end
  end
end

defmodule AshDispatch.Tenancy.WebhookTrustCompatibilityTest do
  @moduledoc """
  The other half of the route-tenant rule: for a host whose receipts are **not**
  per tenant, `:tenant` is the `tenant` column and not a schema name, so an
  unchecked value cannot choose where the library reads. Refusing it would
  break a host that opted into nothing — so it is still used, with no
  `:tenants` anywhere.
  """
  use ExUnit.Case, async: false

  alias AshDispatch.Test.DeliveryReceipt
  alias AshDispatch.WebhookHandlers.Resend

  @moduletag :capture_log

  setup do
    Application.put_env(:ash_dispatch, :delivery_receipt_resource, DeliveryReceipt)
    Application.delete_env(:ash_dispatch, :tenants)

    on_exit(fn -> Application.delete_env(:ash_dispatch, :delivery_receipt_resource) end)

    :ok
  end

  test "a route tenant is used, as it always was" do
    provider_id = "resend_#{System.unique_integer([:positive])}"

    {:ok, receipt} =
      DeliveryReceipt
      |> Ash.Changeset.for_create(:create, %{
        provider_id: provider_id,
        status: :sent,
        recipient: "test@example.com",
        transport: :email
      })
      |> Ash.create()

    refute AshDispatch.Tenancy.receipts_per_tenant?()

    assert {:ok, _} =
             Resend.process_webhook(
               %{
                 "type" => "email.opened",
                 "created_at" => "2026-11-12T10:00:00.000Z",
                 "data" => %{"email_id" => provider_id}
               },
               tenant: "org_1"
             )

    assert Ash.get!(DeliveryReceipt, receipt.id, authorize?: false).opened_at
  end
end
