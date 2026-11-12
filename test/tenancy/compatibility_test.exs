defmodule AshDispatch.Tenancy.CompatibilityTest do
  @moduledoc """
  A host that does nothing sees nothing.

  0.9.4 threads a tenant through eighty-six reads and writes. Ash **tolerates**
  a tenant on a resource that declares no multitenancy — `tenant:` on a read is
  ignored and `set_tenant/2` on a changeset is accepted and unused — so if the
  library leaked one into a public-schema receipt, nothing would fail, no test
  would go red, and the leak would surface years later as a query against a
  schema that does not exist.

  So it is asserted directly, from both ends: a spy on the resources reports
  every tenant they are handed, and the source is held to taking its tenant
  from `AshDispatch.Tenancy` rather than writing one by hand.

  The third proof is the rest of the suite: 884 tests from 0.9.3, unchanged.
  """
  use AshDispatch.Test.InboxCase, async: false

  alias AshDispatch.Test.TenantSpy
  alias AshDispatch.Test.TransportReceipt
  alias AshDispatch.Workers.SendEmail

  @moduletag :capture_log

  defmodule Capture do
    @moduledoc false
    def send_email(_params), do: {:ok, %{id: "provider-id"}}
  end

  setup do
    Application.put_env(:ash_dispatch, :email_backend, Capture)
    TenantSpy.watch()

    on_exit(fn ->
      TenantSpy.stop()
      Application.delete_env(:ash_dispatch, :email_backend)
    end)

    :ok
  end

  describe "a dispatch that carries a tenant, into resources that have none" do
    test "no read of the receipt or the notification is given a tenant" do
      kim = user("kim")

      assert {:ok, _} = send_event(:updated, [kim], tenant: "org_1")

      # `seen/0` drains, so it is read once.
      seen = TenantSpy.seen()
      assert seen != [], "the spy saw nothing — it is not wired up"
      tenants = seen |> Enum.map(fn {_kind, _action, tenant} -> tenant end) |> Enum.uniq()

      assert tenants == [nil], """
      A resource that declares no multitenancy was handed a tenant:

        #{inspect(Enum.reject(seen, fn {_, _, tenant} -> is_nil(tenant) end))}

      Every read and write the library makes must take its tenant from
      `AshDispatch.Tenancy.opts/2`, which answers `[]` for a resource without a
      `multitenancy` block.
      """
    end

    test "no write of the receipt is given one either" do
      kim = user("kim")

      # Ash records a tenant it was given in the returned struct's metadata,
      # even on a resource that ignores it — which is what makes a leaked write
      # visible at all.
      assert {:ok, [{:ok, [receipt]}]} = send_event(:updated, [kim], tenant: "org_1")
      assert Map.get(receipt.__metadata__, :tenant) == nil
    end

    test "the notification created for the recipient carries no tenant of Ash's" do
      kim = user("kim")
      assert {:ok, _} = send_event(:updated, [kim], tenant: "org_1")

      assert [notification] = notifications_for(kim.id)
      assert Map.get(notification.__metadata__, :tenant) == nil

      # The `tenant` COLUMN is still filled, as it has been since 0.9.0. The
      # column and the schema are different things, and this is the column.
      assert notification.tenant == "org_1"
    end

    test "nor does the send worker, which reads the receipt back by id" do
      kim = user("kim")

      receipt =
        TransportReceipt
        |> Ash.Changeset.for_create(:create, %{
          status: :scheduled,
          event_id: "meeting.updated",
          audience: :user,
          transport: :email,
          user_id: kim.id,
          recipient: kim.email,
          subject: "Meeting moved",
          body_text: "The meeting was moved"
        })
        |> Ash.create!(authorize?: false)

      _ = TenantSpy.seen()

      assert :ok = SendEmail.perform(%Oban.Job{args: %{"receipt_id" => receipt.id}})

      assert TenantSpy.tenants() == [nil]
      assert Ash.get!(TransportReceipt, receipt.id, authorize?: false).status == :sent
    end
  end

  describe "structural: the source cannot write a tenant by hand" do
    @lib Path.wildcard("lib/**/*.ex")

    test "the glob found the library" do
      assert length(@lib) > 50, "expected lib/, got #{length(@lib)} files"
    end

    # `AshDispatch.Tenancy` is the only module allowed to put a tenant on a
    # changeset, because it is the only one that asks the resource first.
    test "only AshDispatch.Tenancy calls Ash.Changeset.set_tenant/2" do
      callers =
        Enum.filter(@lib, fn path ->
          File.read!(path) =~ "Ash.Changeset.set_tenant("
        end)

      assert callers == ["lib/tenancy.ex"], """
      These modules set a tenant on a changeset themselves:

        #{inspect(callers -- ["lib/tenancy.ex"])}

      Use `AshDispatch.Tenancy.set/2` (or `changeset_for_update/3`), which puts
      a tenant on a changeset only when the resource declares multitenancy.
      """
    end

    # A `tenant:` written straight into an Ash call bypasses the only place
    # that knows whether the resource wants one.
    @ash_call_with_tenant ~r/Ash\.(get|read|read_one|create|update|destroy|count|load|bulk_[a-z_]+)[!?]?\([^)\n]*tenant:/

    test "no Ash call is given a literal tenant: option" do
      offenders =
        Enum.filter(@lib, fn path ->
          File.read!(path) =~ @ash_call_with_tenant
        end)

      assert offenders == [], """
      These modules pass `tenant:` to Ash directly:

        #{inspect(offenders)}

      Append `AshDispatch.Tenancy.opts(resource, tenant)` instead. It answers
      `[]` for a resource without multitenancy, which is what every host had
      before 0.9.4 — that is the whole compatibility story, and it only holds
      if every call site goes through it.
      """
    end
  end
end
