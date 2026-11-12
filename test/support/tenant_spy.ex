defmodule AshDispatch.Test.TenantSpy do
  @moduledoc """
  Reports the tenant every query and changeset of a watched resource is run
  with, to the process that asked.

  It exists for one assertion: **a resource that declares no multitenancy is
  never given a tenant.** That is the whole compatibility story of 0.9.4, and
  `Ash.Changeset.set_tenant/2` and `tenant:` on a read are both tolerated by
  Ash on a resource that has no multitenancy — they are simply ignored — so
  nothing would fail if the library leaked one. Only a spy notices.

  Inert unless a test calls `watch/0`: the resources that carry the hooks
  (`AshDispatch.Test.TransportReceipt`, `AshDispatch.Test.Inbox.Notification`)
  are used by most of the suite, which must not pay for this.
  """

  @key :ash_dispatch_tenant_spy_pid

  @doc "Reports to this process from now on. Returns `:ok`."
  @spec watch() :: :ok
  def watch do
    Application.put_env(:ash_dispatch, @key, self())
    :ok
  end

  @doc "Stops reporting."
  @spec stop() :: :ok
  def stop do
    Application.delete_env(:ash_dispatch, @key)
    :ok
  end

  @doc false
  # Called from the resources' hooks. Cheap and silent when nobody is watching.
  @spec saw(:read | :write, atom(), term()) :: :ok
  def saw(kind, action, tenant) do
    case Application.get_env(:ash_dispatch, @key) do
      pid when is_pid(pid) -> send(pid, {:tenant_seen, kind, action, tenant})
      _ -> :ok
    end

    :ok
  end

  @doc "Everything seen so far, oldest first: `[{kind, action, tenant}, ...]`."
  @spec seen() :: [{:read | :write, atom(), term()}]
  def seen(acc \\ []) do
    receive do
      {:tenant_seen, kind, action, tenant} -> seen([{kind, action, tenant} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc "The distinct tenants seen so far."
  @spec tenants() :: [term()]
  def tenants do
    seen() |> Enum.map(fn {_kind, _action, tenant} -> tenant end) |> Enum.uniq()
  end
end
