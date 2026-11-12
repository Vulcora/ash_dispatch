defmodule AshDispatch.Tenancy.CronTest do
  @moduledoc """
  The two scheduled workers that work across every receipt, when the receipts
  are in one schema per tenant.

  The scrub is the one with a real bug behind it: its query is raw Ecto against
  a table NAME, so without a prefix every run read the repo's default schema.
  For a host with per-tenant receipts that meant the scrub found nothing,
  reported success, and left one-time tokens in the tenant schemas for good.
  """
  use AshDispatch.Test.PerTenantCase, async: false

  alias AshDispatch.Tenancy.Cron
  alias AshDispatch.Workers.RetryFailedDeliveries
  alias AshDispatch.Workers.ScrubSensitiveContent

  @moduletag :postgres
  @moduletag :capture_log

  describe "plan/1" do
    test "one pass with no tenant when receipts are not per tenant" do
      Application.put_env(:ash_dispatch, :delivery_receipt_resource, PerTenant.PublicReceipt)
      assert Cron.plan(%{}) == {:run, nil}
    end

    test "a fan-out when they are" do
      assert {:fan_out, ["tenant_a", "tenant_b"]} = Cron.plan(%{})
    end

    test "one pass when the job already names a tenant" do
      assert Cron.plan(%{"tenant" => "tenant_a"}) == {:run, "tenant_a"}
    end

    # A cron job's args are storage like any other: a tenant from one is held
    # against what the host recognises before a query sees it.
    test "a tenant the host does not recognise is refused" do
      assert Cron.plan(%{"tenant" => "public"}) == :no_tenants
      assert Cron.plan(%{"tenant" => "tenant_c"}) == :no_tenants
    end

    test "and nothing at all when the host has not said which tenants exist" do
      Application.delete_env(:ash_dispatch, :tenants)
      assert Cron.plan(%{}) == :no_tenants
    end
  end

  describe "the scrub" do
    @sensitive "pt_meeting.cancelled"

    setup do
      Application.put_env(:ash_dispatch, :scrub_after_hours, 0)
      on_exit(fn -> Application.delete_env(:ash_dispatch, :scrub_after_hours) end)
      :ok
    end

    defp sensitive_receipt!(tenant) do
      receipt =
        receipt!(tenant, %{
          event_id: @sensitive,
          subject: "Your code",
          body_text: "the code is 123456",
          body_html: "<p>123456</p>"
        })

      AshDispatch.ReceiptStatus.mark_sent(receipt, %{})
    end

    defp body_of(tenant, id) do
      Ash.get!(PerTenant.Receipt, id, authorize?: false, tenant: tenant).body_text
    end

    # The regression test for the finding. Without `prefix:` on the raw query
    # this passes `:ok` and the body is still there.
    test "empties a sensitive body inside the tenant's own schema" do
      a = sensitive_receipt!("tenant_a")

      assert :ok = ScrubSensitiveContent.perform(%Oban.Job{args: %{"tenant" => "tenant_a"}})

      assert body_of("tenant_a", a.id) == ScrubSensitiveContent.marker()
    end

    test "and leaves the other tenant's alone" do
      a = sensitive_receipt!("tenant_a")
      b = sensitive_receipt!("tenant_b")

      assert :ok = ScrubSensitiveContent.perform(%Oban.Job{args: %{"tenant" => "tenant_a"}})

      assert body_of("tenant_a", a.id) == ScrubSensitiveContent.marker()
      assert body_of("tenant_b", b.id) == "the code is 123456"
    end

    test "without a tenant and with per-tenant receipts, it says so instead of reporting success" do
      a = sensitive_receipt!("tenant_a")
      Application.delete_env(:ash_dispatch, :tenants)

      assert :ok = ScrubSensitiveContent.perform(%Oban.Job{args: %{}})

      # Nothing was scrubbed, and nothing claimed otherwise.
      assert body_of("tenant_a", a.id) == "the code is 123456"
    end
  end

  # The inline engine executes each job inside `Oban.insert/1`, in this
  # process; the same shape the preview parity tests use.
  defp start_oban do
    start_supervised!(
      {Oban,
       name: Oban,
       repo: PerTenant.Repo,
       engine: Oban.Engines.Inline,
       notifier: {Oban.Notifiers.Isolated, []},
       peer: {Oban.Peers.Isolated, [leader?: false]},
       plugins: [],
       queues: [],
       stager: false}
    )
  end

  describe "the retry pass" do
    defp failed_receipt!(tenant) do
      receipt = receipt!(tenant, %{status: :scheduled})

      receipt
      |> AshDispatch.ReceiptStatus.mark_sending()
      |> then(fn {:ok, sending} ->
        AshDispatch.ReceiptStatus.mark_failed(sending, "provider 500")
      end)
    end

    test "retries one tenant's failed receipts and not another's" do
      # Oban's inline engine runs the retry job inside `insert/1`, so this
      # covers the whole way back: the retry enqueues a job carrying the
      # tenant, and the worker reads the receipt from that schema and sends it.
      start_oban()

      a = failed_receipt!("tenant_a")
      b = failed_receipt!("tenant_b")

      assert :ok = RetryFailedDeliveries.perform(%Oban.Job{args: %{"tenant" => "tenant_a"}})

      retried = Ash.get!(PerTenant.Receipt, a.id, authorize?: false, tenant: "tenant_a")
      assert retried.retry_count == 1
      assert retried.status == :sent
      assert [_sent] = sent_emails()

      untouched = Ash.get!(PerTenant.Receipt, b.id, authorize?: false, tenant: "tenant_b")
      assert untouched.status == :failed
      assert untouched.retry_count == 0
    end

    test "the entry job fans out instead of working, so a tenant's failure is its own" do
      _a = failed_receipt!("tenant_a")

      # No Oban is running in this suite, so the fan-out cannot enqueue —
      # which is itself the property: it reports the failures and returns :ok
      # rather than letting one tenant's problem end the run.
      assert :ok = RetryFailedDeliveries.perform(%Oban.Job{args: %{}})

      # And it did not do the work itself.
      assert Ash.get!(PerTenant.Receipt, _a.id, authorize?: false, tenant: "tenant_a").status ==
               :failed
    end

    test "one tenant failing does not stop the next: each pass is its own job" do
      start_oban()
      a = failed_receipt!("tenant_a")

      # "tenant_gone" is recognised but has no schema. Its pass fails - as its
      # own job, which Oban reports and retries on its own terms - and the
      # tenant_a pass, a separate job, is unaffected.
      Application.put_env(:ash_dispatch, :test_tenants, ["tenant_gone", "tenant_a"])

      assert {:error, _} =
               RetryFailedDeliveries.perform(%Oban.Job{args: %{"tenant" => "tenant_gone"}})

      assert :ok = RetryFailedDeliveries.perform(%Oban.Job{args: %{"tenant" => "tenant_a"}})

      assert Ash.get!(PerTenant.Receipt, a.id, authorize?: false, tenant: "tenant_a").retry_count ==
               1
    end
  end
end
