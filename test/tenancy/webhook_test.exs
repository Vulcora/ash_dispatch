defmodule AshDispatch.Tenancy.WebhookTest do
  @moduledoc """
  A provider webhook arrives with a message id and nothing else, so with
  per-tenant receipts it has to say which schema to look in — and it cannot be
  trusted to.

  Two properties here, and the second is the one that matters: a webhook that
  names a tenant its receipt was not sent from updates nothing, and a tenant
  the host does not recognise never reaches a query at all.
  """
  use AshDispatch.Test.PerTenantCase, async: false

  alias AshDispatch.WebhookHandlers.Resend
  alias AshDispatch.Workers.SendEmail

  @moduletag :postgres
  @moduletag :capture_log

  defp sent_receipt!(tenant, provider_id) do
    tenant
    |> receipt!(%{status: :scheduled})
    |> AshDispatch.ReceiptStatus.mark_sent(%{id: provider_id})
  end

  defp opened(provider_id, extra \\ %{}) do
    %{
      "type" => "email.opened",
      "created_at" => "2026-11-12T10:00:00.000Z",
      "data" => Map.merge(%{"email_id" => provider_id}, extra)
    }
  end

  defp reload(tenant, id), do: Ash.get!(PerTenant.Receipt, id, authorize?: false, tenant: tenant)

  describe "an endpoint that knows its tenant" do
    test "finds the receipt in that tenant and records the event" do
      receipt = sent_receipt!("tenant_a", "prov-1")

      assert {:ok, _} = Resend.process_webhook(opened("prov-1"), tenant: "tenant_a")

      assert reload("tenant_a", receipt.id).opened_at
    end

    # The property the brief asks for: a webhook for tenant A's receipt
    # arriving with tenant B's tenant. The id exists in A's schema and nowhere
    # else, so naming B finds nothing — and A's receipt is untouched.
    test "a webhook that names the wrong tenant updates nothing" do
      receipt = sent_receipt!("tenant_a", "prov-2")

      assert {:error, :not_found} = Resend.process_webhook(opened("prov-2"), tenant: "tenant_b")

      refute reload("tenant_a", receipt.id).opened_at
    end

    # A tenant is a schema name, so an unrecognised one is refused before any
    # query runs.
    test "a tenant the host does not recognise is refused, not queried" do
      _receipt = sent_receipt!("tenant_a", "prov-3")

      for unknown <- ["public", "pg_catalog", "tenant_c"] do
        assert {:error, :unknown_tenant} =
                 Resend.process_webhook(opened("prov-3"), tenant: unknown)
      end
    end
  end

  describe "a provider tag" do
    setup do
      Application.put_env(:ash_dispatch, :webhook_tenant_tag, true)
      on_exit(fn -> Application.delete_env(:ash_dispatch, :webhook_tenant_tag) end)
      :ok
    end

    test "rides out with the message" do
      receipt = receipt!("tenant_a", %{status: :scheduled})

      assert :ok =
               SendEmail.perform(%Oban.Job{
                 args: %{"receipt_id" => receipt.id, "tenant" => "tenant_a"}
               })

      assert [%{headers: headers}] = sent_emails()
      assert headers[Resend.tenant_header()] == "tenant_a"
    end

    test "and is read back out of the payload" do
      receipt = sent_receipt!("tenant_a", "prov-4")

      payload =
        opened("prov-4", %{
          "headers" => [%{"name" => Resend.tenant_header(), "value" => "tenant_a"}]
        })

      assert {:ok, _} = Resend.process_webhook(payload)
      assert reload("tenant_a", receipt.id).opened_at
    end

    test "a tag naming another tenant finds nothing, and leaves the real receipt alone" do
      receipt = sent_receipt!("tenant_a", "prov-5")

      payload =
        opened("prov-5", %{
          "headers" => [%{"name" => Resend.tenant_header(), "value" => "tenant_b"}]
        })

      assert {:error, :not_found} = Resend.process_webhook(payload)
      refute reload("tenant_a", receipt.id).opened_at
    end

    test "a tag naming something that is not a tenant is refused" do
      _receipt = sent_receipt!("tenant_a", "prov-6")

      payload =
        opened("prov-6", %{
          "headers" => [%{"name" => Resend.tenant_header(), "value" => "public"}]
        })

      assert {:error, :unknown_tenant} = Resend.process_webhook(payload)
    end

    # The tag comes from outside, so "I cannot check it" is not a reason to
    # trust it — unlike a tenant the host's own router supplied.
    test "a tag is refused when the host has not said which tenants exist" do
      _receipt = sent_receipt!("tenant_a", "prov-7")
      Application.delete_env(:ash_dispatch, :tenants)

      payload =
        opened("prov-7", %{
          "headers" => [%{"name" => Resend.tenant_header(), "value" => "tenant_a"}]
        })

      assert {:error, :unknown_tenant} = Resend.process_webhook(payload)

      # While an explicit tenant from the host's own route still works: it did
      # not come from the payload.
      assert {:ok, _} = Resend.process_webhook(opened("prov-7"), tenant: "tenant_a")
    end

    test "and nothing is read from the payload at all when the tag is switched off" do
      Application.put_env(:ash_dispatch, :webhook_tenant_tag, false)
      receipt = sent_receipt!("tenant_a", "prov-8")

      payload =
        opened("prov-8", %{
          "headers" => [%{"name" => Resend.tenant_header(), "value" => "tenant_a"}]
        })

      # No tenant: with per-tenant receipts there is nowhere to look, and the
      # lookup says so rather than reading some default schema.
      assert {:error, :not_found} = Resend.process_webhook(payload)
      refute reload("tenant_a", receipt.id).opened_at
    end
  end
end
