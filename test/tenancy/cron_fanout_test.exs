defmodule AshDispatch.Tenancy.CronFanOutTest do
  @moduledoc """
  What the fan-out enqueues, and what it answers.

  `docs/design/0.9.4-tenancy.md` gives three reasons for the fan-out, the third
  being "and Oban's `unique` keeps a slow tenant from being enqueued twice".
  Neither worker declared `unique:` and `Cron.fan_out/2` passed none, so every
  crontab tick added one more pass per tenant whatever was still queued — with
  the installer's retry entry and a few hundred tenants, a few hundred jobs a
  minute — and two passes over one tenant could run at once.
  `RetryFailedDeliveries` has `max_attempts: 1` and reads, transitions and
  re-enqueues receipts with no lock of its own.

  And `fan_out/2` answered `:ok` even when it enqueued nothing, so a run that
  did nothing was green in Oban: the failure mode `Cron.no_tenants/1` is
  written to avoid, arrived at by another road.

  No database: these read the DSL and build changesets.
  """
  use ExUnit.Case, async: false

  alias AshDispatch.Tenancy.Cron
  alias AshDispatch.Test.PerTenant
  alias AshDispatch.Workers.RetryFailedDeliveries
  alias AshDispatch.Workers.ScrubSensitiveContent

  @moduletag :capture_log

  setup do
    previous = Application.fetch_env(:ash_dispatch, :delivery_receipt_resource)
    previous_tenants = Application.fetch_env(:ash_dispatch, :tenants)

    Application.put_env(:ash_dispatch, :delivery_receipt_resource, PerTenant.Receipt)
    Application.put_env(:ash_dispatch, :tenants, PerTenant.Tenants)

    on_exit(fn ->
      restore(:delivery_receipt_resource, previous)
      restore(:tenants, previous_tenants)
    end)

    :ok
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:ash_dispatch, key, value)
  defp restore(key, :error), do: Application.delete_env(:ash_dispatch, key)

  describe "the job a fan-out enqueues" do
    for worker <- [RetryFailedDeliveries, ScrubSensitiveContent] do
      test "#{inspect(worker)}'s pass is unique per tenant" do
        job = Ecto.Changeset.apply_changes(Cron.job(unquote(worker), "tenant_a"))

        assert job.args == %{"tenant" => "tenant_a"}
        assert job.unique[:keys] == [:tenant]

        for state <- [:available, :scheduled, :executing, :retryable] do
          assert state in job.unique[:states]
        end
      end
    end

    test "and the tenant in its args is the schema name, not the tenant's key" do
      job =
        Ecto.Changeset.apply_changes(Cron.job(RetryFailedDeliveries, %PerTenant.Org{id: "a"}))

      assert job.args == %{"tenant" => "tenant_a"}
    end

    # On the enqueue and not on the worker: `Oban.Plugins.Cron` inserts the
    # crontab ENTRY job itself, and a `unique` declared on the worker would
    # apply to that insert too — for every host, tenants or not.
    test "the worker itself declares no uniqueness, so the crontab entry is untouched" do
      refute Keyword.has_key?(RetryFailedDeliveries.__opts__(), :unique)
      refute Keyword.has_key?(ScrubSensitiveContent.__opts__(), :unique)

      assert Ecto.Changeset.apply_changes(RetryFailedDeliveries.new(%{})).unique == nil
    end
  end

  describe "a fan-out that enqueued nothing" do
    test "does not report success" do
      # No Oban is running, so every insert raises and is rescued per tenant.
      assert {:fan_out, tenants} = Cron.plan(%{})
      assert tenants == ["tenant_a", "tenant_b"]

      assert {:error, reason} = Cron.fan_out(RetryFailedDeliveries, tenants)
      assert reason =~ "not one of 2 tenant passes could be enqueued"
    end

    test "while a fan-out over no tenants at all is not a failure" do
      assert Cron.fan_out(RetryFailedDeliveries, []) == :ok
    end
  end
end
