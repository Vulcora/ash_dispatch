defmodule AshDispatch.Tenancy.LowerSeverityTest do
  @moduledoc """
  The smaller things the review of 0.9.4-rc.0 turned up.

  Separate from the findings they travel with because each is one property and
  they share nothing but a release.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AshDispatch.Tenancy.Cron
  alias AshDispatch.Tenants
  alias AshDispatch.Test.PerTenant
  alias AshDispatch.Workers.ScrubSensitiveContent
  alias AshDispatch.Workers.SendEmail
  alias AshDispatch.Workers.SendSMS

  @moduletag :capture_log

  setup do
    previous =
      for key <- [:tenants, :delivery_receipt_resource, :notification_resource],
          do: {key, Application.fetch_env(:ash_dispatch, key)}

    on_exit(fn -> Enum.each(previous, fn {key, value} -> restore(key, value) end) end)
    :ok
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:ash_dispatch, key, value)
  defp restore(key, :error), do: Application.delete_env(:ash_dispatch, key)

  describe "the uniqueness key of a send job" do
    # A receipt id is unique per SCHEMA, not across them, so a key that names
    # only the receipt no longer describes the job's identity. Benign with
    # UUID ids and a no-op for a host whose job args carry no `"tenant"` at
    # all, which is every host without tenants.
    test "names the tenant as well as the receipt" do
      assert SendEmail.__opts__()[:unique][:keys] == [:receipt_id, :tenant]
      assert SendSMS.__opts__()[:unique][:keys] == [:receipt_id, :tenant]
    end
  end

  describe "a tenants source that exits rather than raising" do
    # A `DBConnection` timeout in a host's `all/0` exits. Only `rescue` was
    # there, so the exit took the whole cron entry job down instead of being
    # logged like any other unreadable list.
    defmodule Exiting do
      @moduledoc false
      @behaviour AshDispatch.Tenants

      @impl true
      def all, do: exit({:timeout, :db_connection})
    end

    defmodule Throwing do
      @moduledoc false
      @behaviour AshDispatch.Tenants

      @impl true
      def all, do: throw(:nope)
    end

    test "is logged and read as no tenants" do
      Application.put_env(:ash_dispatch, :tenants, Exiting)
      assert Tenants.all() == []

      Application.put_env(:ash_dispatch, :tenants, Throwing)
      assert Tenants.all() == []
    end

    test "and refuses the tenant rather than allowing it" do
      Application.put_env(:ash_dispatch, :tenants, Exiting)
      assert Tenants.check("tenant_a") == {:error, :unknown_tenant}

      Application.put_env(:ash_dispatch, :tenants, Throwing)
      assert Tenants.check("tenant_a") == {:error, :unknown_tenant}
    end
  end

  describe "a fanned-out cron job whose tenant can no longer be checked" do
    test "still runs, and says so" do
      Application.put_env(:ash_dispatch, :delivery_receipt_resource, PerTenant.Receipt)
      Application.delete_env(:ash_dispatch, :tenants)
      :persistent_term.erase({AshDispatch.Tenants, :warned})
      on_exit(fn -> :persistent_term.erase({AshDispatch.Tenants, :warned}) end)

      log =
        capture_log(fn -> assert Cron.plan(%{"tenant" => "tenant_a"}) == {:run, "tenant_a"} end)

      assert log =~ ":tenants is not configured"
    end
  end

  describe "the scrub worker's only perform clause" do
    # `perform(%Oban.Job{args: args})` matches every `%Oban.Job{}`, so the
    # `perform(_job)` that used to sit below it could never run. Removing dead
    # code has nothing to assert, so this asserts what the one clause covers:
    # every plan a job's args can produce.
    test "covers every plan a job's args can produce" do
      Application.put_env(:ash_dispatch, :delivery_receipt_resource, PerTenant.Receipt)
      Application.delete_env(:ash_dispatch, :tenants)

      # :no_tenants — says so rather than reporting a success it did not have.
      assert ScrubSensitiveContent.perform(%Oban.Job{args: %{}}) == :ok

      Application.put_env(:ash_dispatch, :delivery_receipt_resource, PerTenant.PublicReceipt)

      # {:run, nil} — one pass over one table. No event in this case declares
      # `sensitive_content`, so the pass has nothing to scrub and says so
      # without reaching the repo.
      assert ScrubSensitiveContent.perform(%Oban.Job{args: %{}}) == :ok
    end
  end

  describe "a dispatch with no tenant into a resource other than the receipt" do
    # Only the receipt resource was consulted, so a host that switched ONLY
    # `Notification.Base` to `:context` got `TenantRequired` from inside the
    # in-app create — which `ReceiptStatus.mark_failed` turns into an Oban
    # retry, for ever — instead of the loud refusal this release is proud of.
    test "is refused, naming the resource that is per tenant" do
      Application.put_env(:ash_dispatch, :delivery_receipt_resource, PerTenant.PublicReceipt)
      Application.put_env(:ash_dispatch, :notification_resource, PerTenant.Notification)

      refute AshDispatch.Tenancy.receipts_per_tenant?()
      assert AshDispatch.Tenancy.notifications_per_tenant?()

      log =
        capture_log(fn ->
          assert {:error, :tenant_required} =
                   AshDispatch.Dispatcher.dispatch_channel(
                     %AshDispatch.Context{event_id: "e", data: %{}, tenant: nil},
                     %AshDispatch.Channel{transport: :in_app, audience: :user},
                     %{}
                   )
        end)

      assert log =~ "PerTenant.Notification"
      assert log =~ "stores its rows per tenant"
    end

    test "and an email channel on the same host is not, because its receipt is public" do
      Application.put_env(:ash_dispatch, :delivery_receipt_resource, PerTenant.PublicReceipt)
      Application.put_env(:ash_dispatch, :notification_resource, PerTenant.Notification)

      refute match?(
               {:error, :tenant_required},
               AshDispatch.Dispatcher.dispatch_channel(
                 %AshDispatch.Context{event_id: "e", data: %{}, tenant: nil},
                 %AshDispatch.Channel{transport: :email, audience: :user},
                 %{}
               )
             )
    end
  end

  describe "a refused send job's log line" do
    test "is a warning, not an error" do
      Application.put_env(:ash_dispatch, :delivery_receipt_resource, PerTenant.Receipt)
      Application.put_env(:ash_dispatch, :tenants, fn -> ["tenant_a"] end)

      log =
        capture_log(fn ->
          assert {:cancel, _} =
                   AshDispatch.Tenancy.Job.receipt(%{
                     "receipt_id" => Ash.UUID.generate(),
                     "tenant" => "tenant_zzz"
                   })
        end)

      assert log =~ "refusing a send job"
      refute log =~ "[error]"
    end
  end
end
