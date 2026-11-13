defmodule AshDispatch.Tenancy.StructTenantTest do
  @moduledoc """
  A tenant can be a struct whose schema is not its `:id`. That is the shape
  `Ash.ToTenant`'s own moduledoc teaches:

      def to_tenant(%{id: id}, _resource), do: "org_\#{id}"

  The write side was always right — it hands the term to Ash, which applies the
  protocol. The *serialising* side was not: 0.9.4-rc.0 put
  `AshDispatch.Context.tenant_key/1` (the `tenant` column, i.e. the struct's
  `:id`) into the Oban job's args, the cron fan-out's args, the scrub's
  `prefix:`, the outgoing tenant tag and `AshDispatch.Tenants`' comparison. The
  two halves disagreed: the receipt landed in `tenant_a` and the job said `"a"`,
  so every send was cancelled and no tenant was ever scrubbed.

  Everything that becomes a schema name goes through
  `AshDispatch.Tenancy.prefix/2` now. The column is untouched — it has meant
  the key since 0.9.0 and changing it would rewrite stored data (BACKLOG 11).
  """
  use AshDispatch.Test.PerTenantCase, async: false

  alias AshDispatch.Tenancy
  alias AshDispatch.Tenants
  alias AshDispatch.Test.PerTenant.Org
  alias AshDispatch.Test.PerTenant.Schemaless
  alias AshDispatch.Test.PerTenant.StructTenants
  alias AshDispatch.Workers.ScrubSensitiveContent
  alias AshDispatch.Workers.SendEmail

  @moduletag :postgres
  @moduletag :capture_log

  setup do
    Application.put_env(:ash_dispatch, :tenants, StructTenants)
    :ok
  end

  defp org, do: %Org{id: "a"}

  describe "the schema name a struct tenant resolves to" do
    test "prefix/2 answers Ash.ToTenant's schema, not the struct's id" do
      assert Ash.ToTenant.to_tenant(org(), PerTenant.Receipt) == "tenant_a"
      assert Tenancy.prefix(PerTenant.Receipt, org()) == "tenant_a"
      assert Tenancy.receipt_prefix(org()) == "tenant_a"
    end

    test "and the column still holds the key it has held since 0.9.0" do
      # Deliberately unchanged: the `tenant` column is stored data, and
      # rewriting what goes into it is a 0.10.0 change.
      assert Tenancy.key(org()) == "a"
    end

    test "a struct that names its schema directly needs no :id" do
      schemaless = %Schemaless{schema: "tenant_a"}

      assert Tenancy.receipt_prefix(schemaless) == "tenant_a"
    end

    test "a struct with neither an id nor a schema is named, not a Protocol.UndefinedError" do
      assert_raise AshDispatch.Tenancy.UnsupportedTenantError, ~r/cannot reduce/, fn ->
        AshDispatch.Context.tenant_key(%Schemaless{schema: nil})
      end
    end

    test "a string, atom or integer tenant is unchanged" do
      assert Tenancy.receipt_prefix("tenant_a") == "tenant_a"
      assert Tenancy.receipt_prefix(:tenant_a) == "tenant_a"
      assert Tenancy.receipt_prefix(42) == "42"
      assert Tenancy.receipt_prefix(nil) == nil
    end
  end

  describe "the paths that serialise a tenant" do
    test "the send job's args name the schema the receipt is in" do
      receipt = receipt!(org(), %{})

      assert Ash.get!(PerTenant.Receipt, receipt.id, authorize?: false, tenant: "tenant_a")

      args = Tenancy.Job.put_tenant(%{"receipt_id" => receipt.id}, receipt)

      assert args["tenant"] == "tenant_a"
      assert {:ok, _receipt} = Tenancy.Job.receipt(args)
    end

    test "the cron fan-out enqueues the schema name" do
      assert {:fan_out, tenants} = Tenancy.Cron.plan(%{})
      assert Enum.map(tenants, &Tenancy.receipt_prefix/1) == ["tenant_a", "tenant_b"]
    end

    test "the scrub reaches a struct tenant's schema" do
      Application.put_env(:ash_dispatch, :scrub_after_hours, 0)
      on_exit(fn -> Application.delete_env(:ash_dispatch, :scrub_after_hours) end)

      receipt =
        receipt!(org(), %{
          event_id: "pt_meeting.cancelled",
          subject: "Your code",
          body_text: "the code is 123456"
        })

      receipt = AshDispatch.ReceiptStatus.mark_sent(receipt, %{})

      assert {:fan_out, [first | _]} = Tenancy.Cron.plan(%{})
      args = %{"tenant" => Tenancy.receipt_prefix(first)}

      assert :ok = ScrubSensitiveContent.perform(%Oban.Job{args: args})

      body =
        Ash.get!(PerTenant.Receipt, receipt.id, authorize?: false, tenant: "tenant_a").body_text

      assert body == ScrubSensitiveContent.marker()
    end

    test "the tenant tag carries the schema name" do
      Application.put_env(:ash_dispatch, :webhook_tenant_tag, true)
      on_exit(fn -> Application.delete_env(:ash_dispatch, :webhook_tenant_tag) end)

      receipt = receipt!(org(), %{status: :scheduled})

      assert :ok =
               SendEmail.perform(%Oban.Job{
                 args: %{"receipt_id" => receipt.id, "tenant" => "tenant_a"}
               })

      assert [%{headers: headers}] = sent_emails()
      assert headers[AshDispatch.WebhookHandlers.Resend.tenant_header()] == "tenant_a"
    end
  end

  describe "the gate in AshDispatch.Tenants" do
    # Until 0.9.4-rc.1 both sides of the comparison were reduced to the
    # struct's `:id`, so the gate approved `"a"` — a name that is not a schema
    # and cannot be read. It was no protection at all for such a host.
    test "approves the schema name the host's structs resolve to" do
      assert Tenants.check("tenant_a") == :ok
      assert Tenants.check(org()) == :ok
    end

    test "and refuses the struct's bare id" do
      assert Tenants.check("a") == {:error, :unknown_tenant}
    end

    test "so whatever it approves can be read" do
      assert Tenants.check("tenant_a") == :ok
      assert {:ok, _} = Ash.read(PerTenant.Receipt, authorize?: false, tenant: "tenant_a")
    end
  end

  describe "a whole dispatch in a struct tenant" do
    setup do
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

      :ok
    end

    test "delivers its email" do
      kim = user("kim")

      dispatched =
        AshDispatch.Dispatcher.dispatch(
          "pt_meeting.updated",
          %{meeting: meeting(), participants: [kim]},
          %{},
          tenant: org(),
          channels: [%{transport: :email}]
        )

      assert [receipt] = Ash.read!(PerTenant.Receipt, authorize?: false, tenant: "tenant_a")
      assert [_email] = sent_emails(), "dispatch/4 answered #{inspect(dispatched)}"
      assert receipt.status == :sent
    end
  end

  describe "preferences in a struct tenant" do
    test "are written to and read from the tenant's own schema" do
      kim = user("kim")

      assert {:ok, _row} =
               AshDispatch.UserPreference.Resource.put(
                 %{
                   tenant: org(),
                   user_id: kim.id,
                   event_id: "pt_meeting.updated",
                   transport: :email
                 },
                 false,
                 authorize?: false
               )

      assert [row] = preferences("tenant_a")
      assert row.user_id == kim.id
      assert preferences("tenant_b") == []

      refute AshDispatch.UserPreference.Resource.user_allows?(
               kim.id,
               "pt_meeting.updated",
               :email,
               tenant: org()
             )
    end
  end
end
