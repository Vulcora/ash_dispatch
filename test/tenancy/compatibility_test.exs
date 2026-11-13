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

  alias AshDispatch.Test.TenantAudit
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
    # Two text searches until 0.9.4-rc.1 — a `String.contains?` for
    # `"Ash.Changeset.set_tenant("` and a regex for `tenant:` on the same line
    # as an `Ash.` call. They called themselves the structural proof of the
    # guarantee above, and ordinary Elixir got past both; one of them also
    # reported a `@moduledoc` that merely *showed* `Ash.read_one(tenant: ...)`.
    # `AshDispatch.Test.TenantAudit` walks the AST instead.
    test "the audit found the library" do
      assert length(TenantAudit.files()) > 50,
             "expected lib/, got #{length(TenantAudit.files())} files"
    end

    test "nowhere in lib/ does a tenant reach Ash or the repo outside AshDispatch.Tenancy" do
      findings = TenantAudit.findings()

      assert findings == [], """
      A tenant reaches Ash or the repo without going through
      `AshDispatch.Tenancy`:

      #{Enum.map_join(findings, "\n", fn {kind, file, line, snippet} -> "  #{kind} #{file}:#{line}\n    #{snippet}" end)}

      Append `AshDispatch.Tenancy.opts(resource, tenant)`, or use
      `Tenancy.set/2`, `Tenancy.set_query/2`, `Tenancy.changeset_for_update/3`
      or `Tenancy.prefix/2`. `opts/2` answers `[]` for a resource without
      multitenancy, which is what every host had before 0.9.4 — that is the
      whole compatibility story, and it only holds if every call site goes
      through it.
      """
    end
  end

  # What the audit catches, asserted rather than assumed: every one of these
  # is a spelling that got past the two text searches.
  describe "the audit's reach" do
    test "Ash.Query.set_tenant/2, which the string search never named" do
      assert [{:set_tenant, _, _, _}] =
               TenantAudit.source_findings("""
               def leak(resource, tenant) do
                 resource
                 |> Ash.Query.new()
                 |> Ash.Query.set_tenant(tenant)
                 |> Ash.read(authorize?: false)
               end
               """)
    end

    test "a tenant in a variable that is then splatted into the options" do
      assert [{:tainted, _, _, _}] =
               TenantAudit.source_findings("""
               def leak(resource, id, tenant) do
                 opts = [authorize?: false, tenant: tenant]
                 Ash.get(resource, id, opts)
               end
               """)
    end

    test "a call spread over several lines" do
      assert [{:option, _, _, _}] =
               TenantAudit.source_findings("""
               def leak(query, tenant) do
                 Ash.read(
                   query,
                   authorize?: false,
                   tenant: tenant
                 )
               end
               """)
    end

    test "a tenant after a parenthesised argument" do
      assert [{:option, _, _, _} | _] =
               TenantAudit.source_findings("""
               def leak(receipt, tenant) do
                 Ash.update(Ash.Changeset.for_update(receipt, :mark_sent, %{}), tenant: tenant)
               end
               """)
    end

    test "the Ash.Query and Ash.Changeset constructors, which take tenant: too" do
      assert [{:option, _, _, _}] =
               TenantAudit.source_findings("""
               def leak(resource, tenant) do
                 resource
                 |> Ash.Query.for_read(:read, %{}, tenant: tenant)
                 |> Ash.read!(authorize?: false)
               end
               """)

      assert [{:option, _, _, _}] =
               TenantAudit.source_findings("""
               def leak(resource, tenant) do
                 Ash.Changeset.for_create(resource, :create, %{}, tenant: tenant)
               end
               """)
    end

    test "a dynamic call a literal search cannot see" do
      assert [{:dynamic, _, _, _}] =
               TenantAudit.source_findings("""
               def leak(changeset, tenant) do
                 apply(Ash.Changeset, :set_tenant, [changeset, tenant])
               end
               """)
    end

    test "a raw prefix: on the repo, which neither search mentioned" do
      assert [{:option, _, _, _}] =
               TenantAudit.source_findings("""
               def leak(query, tenant) do
                 Config.repo().update_all(query, [], prefix: tenant)
               end
               """)
    end
  end

  describe "and what the audit must not report" do
    test "a tenant that came from AshDispatch.Tenancy" do
      assert TenantAudit.source_findings("""
             def fine(resource, id, tenant) do
               Ash.get(resource, id, [authorize?: false] ++ AshDispatch.Tenancy.opts(resource, tenant))
             end

             def also_fine(query, tenant) do
               Config.repo().update_all(query, [], prefix: AshDispatch.Tenancy.receipt_prefix(tenant))
             end
             """) == []
    end

    test "a `tenant:` in a map, which is an action argument and not an option" do
      assert TenantAudit.source_findings("""
             def fine(resource, tenant, opts) do
               resource
               |> Ash.ActionInput.for_action(:unread_count, %{tenant: tenant}, opts)
               |> Ash.run_action()
             end
             """) == []
    end

    test "prose that merely shows an Ash call with a tenant" do
      assert TenantAudit.source_findings(~S'''
             defmodule Shown do
               @moduledoc """
               The tenant goes into `Ash.read_one(tenant: tenant)`, which is
               what the old regex reported as a call site.
               """
             end
             ''') == []
    end
  end

  # The spy only watches reads: a `change` of its own on the fixture's actions
  # would make them non-atomic, which changes what the rest of the suite is
  # testing. The write half is asserted the way Ash makes it visible — it
  # records a tenant it was given in the returned struct's metadata — and
  # across every resource the library owns rather than the receipt alone.
  describe "the write half, across every resource the library owns" do
    test "nothing the library wrote carries a tenant of Ash's" do
      kim = user("kim")

      put_preference!(%{
        user_id: kim.id,
        event_id: "meeting.updated",
        transport: :email,
        enabled: true
      })

      assert {:ok, [{:ok, [receipt]}]} = send_event(:updated, [kim], tenant: "org_1")
      assert [notification] = notifications_for(kim.id)

      preferences =
        AshDispatch.Test.Inbox.Preference
        |> Ash.read!(authorize?: false)
        |> Enum.map(&{AshDispatch.Test.Inbox.Preference, &1})

      written =
        [
          {TransportReceipt, receipt},
          {AshDispatch.Test.Inbox.Notification, notification}
        ] ++ preferences

      assert length(written) >= 3, "expected a receipt, a notification and a preference row"

      leaked =
        Enum.reject(written, fn {_resource, record} ->
          is_nil(Map.get(record.__metadata__, :tenant))
        end)

      assert leaked == [], """
      These records of resources that declare no multitenancy came back from
      Ash carrying a tenant, which means the library gave it one:

        #{inspect(Enum.map(leaked, fn {resource, _} -> resource end))}
      """

      # And the column is still filled, as it has been since 0.9.0. The column
      # and the schema are different things.
      assert notification.tenant == "org_1"
    end
  end
end
