defmodule AshDispatch.Workers.PruneTenancyPostgresTest do
  @moduledoc """
  The pruner's tenancy, by executing `perform/1` rather than its query
  builders.

  Receipts and notifications take multitenancy **independently**, and the
  first version of this worker read `Tenancy.receipt_prefix/1` for both
  tables and fanned out on `receipts_per_tenant?/0` alone. So with per-tenant
  notifications and public receipts it deleted from `public` across every
  tenant's rows, and with the other mix it never ran per tenant at all. The
  tests called the query builders directly, which is how it survived.
  """
  use AshDispatch.Test.PerTenantCase, async: false

  alias AshDispatch.Test.PerTenant
  alias AshDispatch.Workers.Prune

  @moduletag :postgres

  @tenant "tenant_a"
  @other "tenant_b"

  defp put_env(key, value) do
    previous = Application.fetch_env(:ash_dispatch, key)
    Application.put_env(:ash_dispatch, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:ash_dispatch, key, old)
        :error -> Application.delete_env(:ash_dispatch, key)
      end
    end)
  end

  defp old, do: DateTime.add(DateTime.utc_now(), -100 * 3600, :second)

  # Written straight to the data layer: no action accepts a timestamp, and
  # these rows have to be older than the window.
  defp notification!(prefix, occurred_at \\ nil) do
    id = Ecto.UUID.generate()
    at = occurred_at || old()
    schema = if prefix, do: ~s("#{prefix}".), else: ""

    PerTenant.Repo.query!(
      "insert into #{schema}\"pt_notifications\" " <>
        "(id, user_id, event_id, type, title, message, metadata, read, " <>
        "occurred_at, inserted_at, updated_at) " <>
        "values ($1, $2, $3, 'info', $4, $5, '{}'::jsonb, false, $6, $7, $7)",
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        "ticket.created",
        "t",
        "m",
        at,
        at
      ]
    )

    id
  end

  defp notification_ids(prefix, table \\ "pt_notifications") do
    schema = if prefix, do: ~s("#{prefix}".), else: ""
    %{rows: rows} = PerTenant.Repo.query!("select id from #{schema}\"#{table}\"")
    rows |> List.flatten() |> Enum.map(&Ecto.UUID.load!/1) |> Enum.sort()
  end

  describe "per-tenant notifications, public receipts" do
    setup do
      put_env(:notification_resource, PerTenant.Notification)
      put_env(:delivery_receipt_resource, PerTenant.PublicReceipt)
      put_env(:notification_retention_hours, 24)
      :ok
    end

    test "each tenant's notifications are deleted in that tenant's own schema" do
      a = notification!(@tenant)
      b = notification!(@other)

      assert :ok = Prune.perform(%Oban.Job{args: %{"tenant" => @tenant}})

      # Only tenant_a's pass ran, so only tenant_a's row is gone.
      refute a in notification_ids(@tenant)
      assert b in notification_ids(@other)
    end

    test "and the plan is a fan-out even though the receipts are public" do
      # `receipts_per_tenant?/0` is false here. Gating on it alone meant the
      # pass ran ONCE, with no tenant, against `public` — which for a
      # per-tenant notification resource is not where the rows are. The plan
      # rather than `perform/1`, because the fan-out enqueues Oban jobs and
      # there is no Oban in this test.
      assert {:fan_out, tenants} =
               AshDispatch.Tenancy.Cron.plan(
                 %{},
                 AshDispatch.Tenancy.receipts_per_tenant?() or
                   AshDispatch.Tenancy.notifications_per_tenant?()
               )

      assert @tenant in tenants

      # And the old gate would have answered this instead.
      refute AshDispatch.Tenancy.receipts_per_tenant?()

      assert {:run, nil} =
               AshDispatch.Tenancy.Cron.plan(%{}, AshDispatch.Tenancy.receipts_per_tenant?())
    end
  end

  describe "per-tenant receipts, public notifications" do
    setup do
      put_env(:notification_resource, PerTenant.PublicNotification)
      put_env(:delivery_receipt_resource, PerTenant.Receipt)
      put_env(:notification_retention_hours, 24)
      :ok
    end

    test "the public notification table is addressed without a prefix" do
      # The receipt's prefix was used for this query, so a `tenant_a` pass
      # looked for `tenant_a.pt_public_notifications`, which does not exist.
      id = public_notification!()

      assert :ok = Prune.perform(%Oban.Job{args: %{"tenant" => @tenant}})

      refute id in notification_ids(nil, "pt_public_notifications")
    end
  end

  describe "both per tenant" do
    setup do
      put_env(:notification_resource, PerTenant.Notification)
      put_env(:delivery_receipt_resource, PerTenant.Receipt)
      put_env(:notification_retention_hours, 24)
      put_env(:receipt_retention_hours, 24)
      :ok
    end

    test "one tenant's pass deletes in that tenant's schema and nowhere else" do
      # The shape the first version of this worker could not do at all, and
      # the one the earlier tests only checked through the query builders.
      a_note = notification!(@tenant)
      b_note = notification!(@other)
      a_receipt = per_tenant_receipt!(@tenant)
      b_receipt = per_tenant_receipt!(@other)

      assert :ok = Prune.perform(%Oban.Job{args: %{"tenant" => @tenant}})

      refute a_note in notification_ids(@tenant)
      refute a_receipt in receipt_ids(@tenant)

      assert b_note in notification_ids(@other)
      assert b_receipt in receipt_ids(@other)
    end

    test "and a second pass clears the other one" do
      a = notification!(@tenant)
      b = notification!(@other)

      assert :ok = Prune.perform(%Oban.Job{args: %{"tenant" => @tenant}})
      assert :ok = Prune.perform(%Oban.Job{args: %{"tenant" => @other}})

      refute a in notification_ids(@tenant)
      refute b in notification_ids(@other)
    end
  end

  describe "the digest summary" do
    setup do
      # Both public, so the pass runs here rather than fanning out.
      put_env(:delivery_receipt_resource, PerTenant.PublicReceipt)
      put_env(:notification_resource, PerTenant.PublicNotification)
      put_env(:body_retention_hours, 24)
      :ok
    end

    test "is stripped too — it is the fourth place a body lives" do
      # A batched email stores the first 280 characters of its text under
      # `content['digest']['item']['summary']` for the digest to list. Leaving
      # it was worse than missing it once: after one pass the row is never
      # SELECTED again, so the paragraph stayed for good.
      id = batched_receipt!()

      assert :ok = Prune.perform(%Oban.Job{args: %{}})

      content = receipt_content(id)

      refute get_in(content, ["digest", "item", "summary"])
      # The rest of the digest bookkeeping is untouched: the window it waited
      # in is not a body.
      assert get_in(content, ["digest", "window"])
    end

    test "and a row that only has the summary left is still selected" do
      id = batched_receipt!(body_text: nil, body_html: nil, keep_copies?: false)

      assert :ok = Prune.perform(%Oban.Job{args: %{}})

      refute get_in(receipt_content(id), ["digest", "item", "summary"])
    end

    test "a receipt that was never batched is untouched where the digest would be" do
      id = plain_receipt!()

      assert :ok = Prune.perform(%Oban.Job{args: %{}})

      content = receipt_content(id)

      # `jsonb_set(..., create_if_missing: false)` leaves it alone.
      refute Map.has_key?(content, "digest")
      refute Map.has_key?(content, "text_body")
    end
  end

  describe "nothing configured" do
    setup do
      put_env(:notification_resource, PerTenant.Notification)
      put_env(:delivery_receipt_resource, PerTenant.Receipt)
      :ok
    end

    test "is inert BEFORE the fan-out — not a job per tenant per night" do
      # With no window there is nothing to do in any schema. Answering from
      # the top is the difference between one no-op and one no-op per tenant.
      assert :ok = Prune.perform(%Oban.Job{args: %{}})
    end
  end

  describe "Receipts.record/3 and the tenant" do
    setup do
      put_env(:delivery_receipt_resource, PerTenant.PublicReceipt)
      put_env(:notification_resource, PerTenant.PublicNotification)
      :ok
    end

    test "fills the tenant COLUMN on a host with tenant_column: true" do
      # The tenant was popped out of the attributes and used only as the
      # write's tenant, so on exactly the configuration the column exists for
      # the recorded receipt had a NULL tenant.
      assert {:ok, receipt} =
               AshDispatch.Receipts.record(
                 %{
                   event_id: "bookings.reminder",
                   transport: :sms,
                   audience: :user,
                   recipient: "+46701234567",
                   tenant: @tenant
                 },
                 {:sent, %{id: "prov-1"}}
               )

      assert receipt.tenant == @tenant
      assert Ash.get!(PerTenant.PublicReceipt, receipt.id, authorize?: false).tenant == @tenant
    end

    test "and writes into the tenant's schema for a per-tenant receipt resource" do
      put_env(:delivery_receipt_resource, PerTenant.Receipt)

      assert {:ok, receipt} =
               AshDispatch.Receipts.record(
                 %{
                   event_id: "bookings.reminder",
                   transport: :sms,
                   audience: :user,
                   recipient: "+46701234567",
                   tenant: @tenant
                 },
                 {:sent, %{id: "prov-2"}}
               )

      # In `tenant_a`, and nowhere else.
      assert Ash.get!(PerTenant.Receipt, receipt.id, tenant: @tenant, authorize?: false)

      assert_raise Ash.Error.Invalid, fn ->
        Ash.get!(PerTenant.Receipt, receipt.id, tenant: @other, authorize?: false)
      end
    end

    test "an outcome that is not an outcome leaves no :pending row behind" do
      before = receipt_count()

      assert {:error, {:unknown_outcome, :maybe}} =
               AshDispatch.Receipts.record(
                 %{event_id: "x", transport: :sms, audience: :user, recipient: "+46"},
                 :maybe
               )

      assert receipt_count() == before
    end
  end

  defp receipt_count do
    %{rows: [[count]]} =
      PerTenant.Repo.query!("select count(*) from \"pt_public_receipts\"")

    count
  end

  defp per_tenant_receipt!(prefix) do
    id = Ecto.UUID.generate()
    at = old()

    PerTenant.Repo.query!(
      ~s(insert into "#{prefix}"."pt_receipts" ) <>
        "(id, event_id, transport, audience, status, recipient, content, " <>
        "provider_response, retry_count, inserted_at, updated_at) " <>
        "values ($1, $2, 'email', 'user', 'sent', $3, '{}'::jsonb, '{}'::jsonb, 0, $4, $4)",
      [Ecto.UUID.dump!(id), "orders.created", "a@b.c", at]
    )

    id
  end

  defp receipt_ids(prefix) do
    %{rows: rows} = PerTenant.Repo.query!(~s(select id from "#{prefix}"."pt_receipts"))
    rows |> List.flatten() |> Enum.map(&Ecto.UUID.load!/1) |> Enum.sort()
  end

  defp batched_receipt!(opts \\ []) do
    id = Ecto.UUID.generate()
    at = old()

    content =
      if Keyword.get(opts, :keep_copies?, true) do
        ~s({"text_body": "Dear Alva", "digest": {"window": "daily", )
      else
        ~s({"digest": {"window": "daily", )
      end <> ~s("item": {"title": "Your order", "summary": "Dear Alva, your order..."}}})

    PerTenant.Repo.query!(
      "insert into \"pt_public_receipts\" " <>
        "(id, event_id, transport, audience, status, recipient, body_text, body_html, " <>
        "content, provider_response, retry_count, inserted_at, updated_at) " <>
        "values ($1, $2, 'email', 'user', 'sent', $3, $4, $5, $6::text::jsonb, " <>
        "'{}'::jsonb, 0, $7, $7)",
      [
        Ecto.UUID.dump!(id),
        "orders.created",
        "a@b.c",
        Keyword.get(opts, :body_text, "Dear Alva"),
        Keyword.get(opts, :body_html, "<p>Dear Alva</p>"),
        content,
        at
      ]
    )

    id
  end

  defp plain_receipt! do
    id = Ecto.UUID.generate()
    at = old()

    PerTenant.Repo.query!(
      "insert into \"pt_public_receipts\" " <>
        "(id, event_id, transport, audience, status, recipient, body_text, " <>
        "content, provider_response, retry_count, inserted_at, updated_at) " <>
        "values ($1, $2, 'email', 'user', 'sent', $3, $4, '{\"subject\": \"x\"}'::jsonb, " <>
        "'{}'::jsonb, 0, $5, $5)",
      [Ecto.UUID.dump!(id), "orders.created", "a@b.c", "Dear Alva", at]
    )

    id
  end

  defp receipt_content(id) do
    %{rows: [[content]]} =
      PerTenant.Repo.query!("select content from \"pt_public_receipts\" where id = $1", [
        Ecto.UUID.dump!(id)
      ])

    content
  end

  defp public_notification! do
    id = Ecto.UUID.generate()
    at = old()

    PerTenant.Repo.query!(
      "insert into \"pt_public_notifications\" " <>
        "(id, user_id, event_id, type, title, message, metadata, read, " <>
        "occurred_at, inserted_at, updated_at) " <>
        "values ($1, $2, $3, 'info', $4, $5, '{}'::jsonb, false, $6, $7, $7)",
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        "ticket.created",
        "t",
        "m",
        at,
        at
      ]
    )

    id
  end
end
