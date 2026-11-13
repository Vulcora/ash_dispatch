defmodule AshDispatch.Tenancy.TenantsCostTest do
  @moduledoc """
  What one `AshDispatch.Tenants.check/1` costs the host.

  `check/1` reads `:tenants`, then `ask_known?/2` called `member?/1`, which
  called `all/0`, which read `:tenants` again and ran the host's query. The
  guide's own `all/0` is an `Ash.read!` of an organisation resource, and
  `check/1` runs on every send job and on every unauthenticated POST to the
  webhook endpoint — "the one place in the library an outsider can trigger
  work".

  The source `check/1` already read is passed down now, so the host is asked
  at most once per check, and not at all when it implements `known?/1`. That
  is a bound a test can hold, which a comment is not.
  """
  use ExUnit.Case, async: false

  alias AshDispatch.Tenancy
  alias AshDispatch.Tenants

  @moduletag :capture_log

  defmodule Counting do
    @moduledoc false
    @behaviour AshDispatch.Tenants

    @impl true
    def all do
      count = :persistent_term.get({__MODULE__, :calls}, 0)
      :persistent_term.put({__MODULE__, :calls}, count + 1)
      ["tenant_a", "tenant_b"]
    end

    def calls, do: :persistent_term.get({__MODULE__, :calls}, 0)
    def reset, do: :persistent_term.put({__MODULE__, :calls}, 0)
  end

  defmodule CountingWithKnown do
    @moduledoc false
    @behaviour AshDispatch.Tenants

    @impl true
    def all do
      AshDispatch.Tenancy.TenantsCostTest.Counting.all()
    end

    @impl true
    def known?(tenant), do: tenant in ["tenant_a", "tenant_b"]
  end

  setup do
    previous = Application.fetch_env(:ash_dispatch, :tenants)
    previous_receipt = Application.fetch_env(:ash_dispatch, :delivery_receipt_resource)

    Application.put_env(:ash_dispatch, :tenants, Counting)

    Application.put_env(
      :ash_dispatch,
      :delivery_receipt_resource,
      AshDispatch.Test.PerTenant.Receipt
    )

    Counting.reset()

    on_exit(fn ->
      restore(:tenants, previous)
      restore(:delivery_receipt_resource, previous_receipt)
    end)

    :ok
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:ash_dispatch, key, value)
  defp restore(key, :error), do: Application.delete_env(:ash_dispatch, key)

  test "one check asks the host for its tenants once" do
    assert Tenants.check("tenant_a") == :ok

    assert Counting.calls() == 1,
           "the host's all/0 ran #{Counting.calls()} times to answer one check/1"
  end

  test "and a refusal costs the same" do
    assert Tenants.check("tenant_zzz") == {:error, :unknown_tenant}
    assert Counting.calls() == 1
  end

  test "a send job's tenant is one check, not more" do
    assert Tenancy.from_job_args(%{"tenant" => "tenant_a"}) == {:ok, "tenant_a"}
    assert Counting.calls() == 1
  end

  test "and with known?/1 the host is not asked for a list at all" do
    Application.put_env(:ash_dispatch, :tenants, CountingWithKnown)

    assert Tenants.check("tenant_a") == :ok
    assert Tenants.check("tenant_zzz") == {:error, :unknown_tenant}

    assert Counting.calls() == 0, """
    `known?/1` exists so a host whose `all/0` is expensive can answer with one
    query. It is the answer the webhook endpoint should be able to rely on.
    """
  end

  test "a fan-out's plan asks once, and each fanned-out job asks once" do
    assert {:fan_out, tenants} = Tenancy.Cron.plan(%{})
    assert Counting.calls() == 1

    Counting.reset()
    Enum.each(tenants, fn tenant -> Tenancy.Cron.plan(%{"tenant" => tenant}) end)

    assert Counting.calls() == length(tenants)
  end
end
