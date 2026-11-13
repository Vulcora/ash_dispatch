defmodule AshDispatch.Tenancy.SendPathTest do
  @moduledoc """
  The tenant from the dispatch to the provider, through two real schemas.

  What is under test is not that a keyword list was passed: the receipts, the
  notifications and the preferences are in `tenant_a` and `tenant_b`, and the
  question at every step is which schema the row ended up in — and, as often,
  which schema a row could be reached from.
  """
  use AshDispatch.Test.PerTenantCase, async: false

  alias AshDispatch.Tenancy
  alias AshDispatch.Workers.SendEmail

  @moduletag :postgres
  @moduletag :capture_log

  describe "a dispatch inside a tenant" do
    test "writes its receipt and its notification into that tenant's schema" do
      kim = user("kim")

      assert {:ok, _} = send_event(:updated, "tenant_a", [kim])

      assert [receipt] = receipts("tenant_a")
      assert receipt.event_id == "pt_meeting.updated"
      assert receipt.status == :sent
      assert receipt.__meta__.prefix == "tenant_a"

      assert [notification] = notifications("tenant_a")
      assert notification.user_id == kim.id

      assert receipts("tenant_b") == []
      assert notifications("tenant_b") == []
    end

    test "two tenants never see each other's rows through any public function" do
      a = user("a")
      b = user("b")

      assert {:ok, _} = send_event(:updated, "tenant_a", [a])
      assert {:ok, _} = send_event(:updated, "tenant_b", [b])

      assert Enum.map(receipts("tenant_a"), & &1.user_id) == [a.id]
      assert Enum.map(receipts("tenant_b"), & &1.user_id) == [b.id]

      assert Enum.map(notifications("tenant_a"), & &1.user_id) == [a.id]
      assert Enum.map(notifications("tenant_b"), & &1.user_id) == [b.id]

      # The unread count a bell shows, and the list behind it.
      assert {:ok, 1} =
               AshDispatch.Helpers.NotificationLoader.unread_count(
                 actor: %{id: a.id},
                 tenant: "tenant_a"
               )

      assert {:ok, 0} =
               AshDispatch.Helpers.NotificationLoader.unread_count(
                 actor: %{id: a.id},
                 tenant: "tenant_b"
               )
    end

    test "a preference set in one tenant does not gate the other" do
      kim = user("kim")

      put_preference!("tenant_a", %{
        user_id: kim.id,
        event_id: "pt_meeting.updated",
        transport: :in_app,
        enabled: false
      })

      assert {:ok, _} = send_event(:updated, "tenant_a", [kim])
      assert [%{status: :skipped, error_message: "user_opted_out"}] = receipts("tenant_a")

      assert {:ok, _} = send_event(:updated, "tenant_b", [kim])
      assert [%{status: :sent}] = receipts("tenant_b")

      assert length(preferences("tenant_a")) == 1
      assert preferences("tenant_b") == []
    end
  end

  describe "without a tenant" do
    # Not a fallback to `public`: two homes for receipts is how a receipt stops
    # being an audit trail.
    test "a dispatch is refused, loudly, and writes nothing" do
      kim = user("kim")

      assert {:error, :all_dispatches_failed} =
               AshDispatch.Dispatcher.dispatch(
                 "pt_meeting.updated",
                 %{meeting: meeting(), participants: [kim]},
                 %{},
                 channels: [%{transport: :in_app}]
               )

      for tenant <- tenants(), do: assert(receipts(tenant) == [])
    end
  end

  describe "the send job" do
    test "carries the tenant, and the worker reads the receipt from that schema" do
      kim = user("kim")
      receipt = receipt!("tenant_a", %{status: :scheduled, recipient: kim.email})

      assert :ok = SendEmail.perform(%Oban.Job{args: job_args(receipt, "tenant_a")})

      assert [%{to: to}] = sent_emails()
      assert to == kim.email

      assert Ash.get!(PerTenant.Receipt, receipt.id, authorize?: false, tenant: "tenant_a").status ==
               :sent
    end

    # The receipt id exists in tenant A's schema and nowhere else, so naming
    # another tenant cannot reach it. Fail closed by construction.
    test "a job edited to name another tenant finds nothing and sends nothing" do
      receipt = receipt!("tenant_a", %{status: :scheduled})

      assert {:error, :receipt_not_found} =
               SendEmail.perform(%Oban.Job{args: job_args(receipt, "tenant_b")})

      assert sent_emails() == []

      # And tenant A's receipt is untouched.
      assert Ash.get!(PerTenant.Receipt, receipt.id, authorize?: false, tenant: "tenant_a").status ==
               :scheduled
    end

    # A tenant is a Postgres schema name. An args row someone has edited must
    # not be able to choose which schema is read.
    test "a tenant the host does not recognise is refused before any query" do
      receipt = receipt!("tenant_a", %{status: :scheduled})

      for unknown <- ["public", "pg_catalog", "tenant_c"] do
        assert {:cancel, reason} =
                 SendEmail.perform(%Oban.Job{args: job_args(receipt, unknown)})

        assert reason =~ "not one this host recognises"
      end

      assert sent_emails() == []
    end

    # 0.9.4-rc.0 cancelled here, on `42P01`. Postgres says `42P01` both for a
    # schema that does not exist and for a schema whose tables are not migrated
    # YET, and the second is the normal state of a tenant between
    # `create schema` and `mix ash.migrate` — so cancelling threw away a
    # tenant's mail for a migration that was still running. Retrying a tenant
    # that will never exist costs five attempts; the other mistake costs the
    # letter. See `AshDispatch.Tenancy.missing_schema?/1`.
    test "a tenant the host recognises but that has no tables is retried, not cancelled" do
      receipt = receipt!("tenant_a", %{status: :scheduled})
      Application.put_env(:ash_dispatch, :test_tenants, ["tenant_a", "tenant_gone"])

      assert {:error, _reason} =
               SendEmail.perform(%Oban.Job{args: job_args(receipt, "tenant_gone")})

      assert sent_emails() == []

      # And the receipt in the tenant it really is in is untouched, so the
      # retry has something to send.
      assert Ash.get!(PerTenant.Receipt, receipt.id, authorize?: false, tenant: "tenant_a").status ==
               :scheduled
    end

    test "a job from before 0.9.4 carries no tenant and behaves as it did" do
      # With per-tenant receipts there is no schema to read it from, so it
      # fails — the point is that it fails cleanly rather than reading `public`.
      receipt = receipt!("tenant_a", %{status: :scheduled})

      assert {:error, _} = SendEmail.perform(%Oban.Job{args: %{"receipt_id" => receipt.id}})
      assert sent_emails() == []
    end
  end

  describe "the status transitions" do
    test "every one of them lands in the schema the receipt came from" do
      receipt = receipt!("tenant_a", %{status: :scheduled})

      assert receipt |> Tenancy.remember("tenant_a") |> then(&Tenancy.of(&1)) == "tenant_a"

      sending = AshDispatch.ReceiptStatus.mark_sending(Tenancy.remember(receipt, "tenant_a"))
      assert {:ok, sending} = sending
      assert Tenancy.of(sending) == "tenant_a"

      sent = AshDispatch.ReceiptStatus.mark_sent(sending, %{id: "p1"})
      assert sent.status == :sent
      assert sent.provider_id == "p1"

      # Read back from the tenant, and absent from the other.
      assert Ash.get!(PerTenant.Receipt, receipt.id, authorize?: false, tenant: "tenant_a").status ==
               :sent

      assert {:error, _} =
               Ash.get(PerTenant.Receipt, receipt.id, authorize?: false, tenant: "tenant_b")
    end
  end

  describe "job_args: :minimal" do
    test "is the default when receipts are per tenant: no body in the job table" do
      assert AshDispatch.Config.job_args() == :minimal

      args =
        AshDispatch.Transports.Email.job_args(
          receipt!("tenant_a", %{}),
          %AshDispatch.Context{event_id: "pt_meeting.updated", data: %{}, tenant: "tenant_a"},
          %AshDispatch.Channel{transport: :email, audience: :user}
        )

      assert args["receipt_id"]
      assert args["tenant"] == "tenant_a"
      refute Map.has_key?(args, "html_body")
      refute Map.has_key?(args, "text_body")
      refute Map.has_key?(args, "subject")
    end

    test "and the worker sends what the receipt holds" do
      receipt =
        receipt!("tenant_a", %{
          status: :scheduled,
          subject: "From the receipt",
          body_text: "the body"
        })

      assert :ok = SendEmail.perform(%Oban.Job{args: job_args(receipt, "tenant_a")})

      assert [%{subject: "From the receipt", text_body: "the body"}] = sent_emails()
    end

    test ":full can be asked for explicitly, and then the args carry the letter" do
      Application.put_env(:ash_dispatch, :job_args, :full)
      on_exit(fn -> Application.delete_env(:ash_dispatch, :job_args) end)

      args =
        AshDispatch.Transports.Email.job_args(
          receipt!("tenant_a", %{subject: "In the args"}),
          %AshDispatch.Context{event_id: "pt_meeting.updated", data: %{}, tenant: "tenant_a"},
          %AshDispatch.Channel{transport: :email, audience: :user}
        )

      assert args["subject"] == "In the args"
      assert args["tenant"] == "tenant_a"
    end

    test "a sensitive event is minimal whatever the setting says" do
      Application.put_env(:ash_dispatch, :job_args, :full)
      on_exit(fn -> Application.delete_env(:ash_dispatch, :job_args) end)

      assert AshDispatch.Transports.Email.minimal_args?("pt_meeting.cancelled")
      refute AshDispatch.Transports.Email.minimal_args?("pt_meeting.updated")
    end
  end

  defp job_args(receipt, tenant), do: %{"receipt_id" => receipt.id, "tenant" => tenant}
end
