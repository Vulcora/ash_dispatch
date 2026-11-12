defmodule AshDispatch.TenantsTest do
  @moduledoc """
  Which tenants exist is the one question the library cannot answer for itself,
  and the one a tenant arriving from outside has to be held against: a tenant
  is a Postgres schema name, so a string that reaches a query unchecked chooses
  which schema is read.
  """
  use ExUnit.Case, async: false

  alias AshDispatch.Tenants

  @moduletag :capture_log

  defmodule Listed do
    @moduledoc false
    @behaviour AshDispatch.Tenants

    @impl true
    def all, do: ["org_1", "org_2"]
  end

  defmodule WithKnown do
    @moduledoc false
    @behaviour AshDispatch.Tenants

    @impl true
    def all, do: raise("all/0 must not be called when known?/1 can answer")

    @impl true
    def known?(tenant), do: tenant == "org_1"
  end

  defmodule Raising do
    @moduledoc false
    @behaviour AshDispatch.Tenants

    @impl true
    def all, do: raise("the tenant table is unreachable")
  end

  def two_tenants, do: ["org_1", "org_2"]

  setup do
    on_exit(fn -> Application.delete_env(:ash_dispatch, :tenants) end)
    Application.delete_env(:ash_dispatch, :tenants)
    :ok
  end

  defp put(source), do: Application.put_env(:ash_dispatch, :tenants, source)

  describe "without a source" do
    test "there are no tenants and no answer about one" do
      refute Tenants.configured?()
      assert Tenants.all() == []
      assert Tenants.check("org_1") == {:error, :not_configured}
    end

    test "a nil tenant needs no answer" do
      assert Tenants.check(nil) == :ok
    end
  end

  describe "every form of the setting" do
    test "a module implementing the behaviour" do
      put(Listed)
      assert Tenants.all() == ["org_1", "org_2"]
      assert Tenants.configured?()
    end

    test "{module, function}" do
      put({__MODULE__, :two_tenants})
      assert Tenants.all() == ["org_1", "org_2"]
    end

    test "{module, function, args}" do
      put({Enum, :map, [["a", "b"], &String.upcase/1]})
      assert Tenants.all() == ["A", "B"]
    end

    test "a zero-argument function" do
      put(fn -> ["org_9"] end)
      assert Tenants.all() == ["org_9"]
    end

    test "a setting that cannot be called is reported, not raised" do
      put("MyApp.Tenants")
      assert Tenants.all() == []
    end
  end

  describe "check/1" do
    test "a tenant on the list is allowed" do
      put(Listed)
      assert Tenants.check("org_1") == :ok
      assert Tenants.check("org_2") == :ok
    end

    # The property that matters: a tenant that arrived from outside and is not
    # the host's does not reach a query.
    test "a tenant that is not on the list is refused" do
      put(Listed)
      assert Tenants.check("public") == {:error, :unknown_tenant}
      assert Tenants.check("pg_catalog") == {:error, :unknown_tenant}
      assert Tenants.check("org_3") == {:error, :unknown_tenant}
      assert Tenants.check("org_1; drop schema public cascade") == {:error, :unknown_tenant}
    end

    test "known?/1 answers when the host implements it, and all/0 is not asked" do
      put(WithKnown)
      assert Tenants.check("org_1") == :ok
      assert Tenants.check("org_2") == {:error, :unknown_tenant}
    end

    test "a tenant given as a struct and listed as a string still match" do
      put(Listed)
      assert Tenants.check(%{id: "org_1"}) == :ok
    end

    test "a source that raises refuses the tenant rather than allowing it" do
      put(Raising)
      assert Tenants.check("org_1") == {:error, :unknown_tenant}
      assert Tenants.all() == []
    end
  end
end
