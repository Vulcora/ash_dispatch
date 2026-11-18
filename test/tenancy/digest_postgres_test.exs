defmodule AshDispatch.Tenancy.DigestPostgresTest do
  @moduledoc """
  Digests on the real `DeliveryReceipt.Base`, in two real schemas.

  The ETS suite (`test/digest_test.exs`) covers the decisions. This one
  covers what only a database can: the state machine's transitions on the
  real resource, the digest bookkeeping surviving a JSONB round trip with
  string keys, the digest receipt and the entries' move written in one
  transaction through the configured repo, and a tenant's digest staying in
  that tenant.
  """
  use AshDispatch.Test.PerTenantCase, async: false

  alias AshDispatch.Channel
  alias AshDispatch.Context
  alias AshDispatch.Digest
  alias AshDispatch.Transports.Email

  @moduletag :postgres
  @moduletag :capture_log

  @window "quiet:300:1800"

  setup do
    start_supervised!(
      {Oban,
       name: Oban,
       repo: AshDispatch.Test.PerTenant.Repo,
       engine: Oban.Engines.Inline,
       notifier: {Oban.Notifiers.Isolated, []},
       peer: {Oban.Peers.Isolated, [leader?: false]},
       plugins: [],
       queues: [],
       stager: false}
    )

    :ok
  end

  defp batch!(tenant, attrs) do
    receipt = receipt!(tenant, attrs)

    {:ok, batched} =
      Email.deliver(
        receipt,
        %Context{event_id: "pt_meeting.updated", data: %{}, tenant: tenant},
        %Channel{transport: :email, audience: :user, time: {:digest, {:quiet, 300}}},
        []
      )

    batched
  end

  defp later, do: DateTime.add(DateTime.utc_now(), 301, :second)

  test "two emails in one tenant become one digest there, and nothing moves in the other" do
    kim = user("kim")

    first =
      batch!("tenant_a", %{recipient: kim.email, user_id: kim.id, subject: "Moved to 10:00"})

    second = batch!("tenant_a", %{recipient: kim.email, user_id: kim.id, subject: "Room 4"})
    other = batch!("tenant_b", %{recipient: kim.email, user_id: kim.id, subject: "Elsewhere"})

    # Read back from Postgres: the bookkeeping has string keys now.
    [stored | _] = receipts("tenant_a")
    assert stored.status == :batched

    assert %{"window" => @window, "batched_at" => _, "item" => %{"title" => _}} =
             stored.content["digest"]

    assert :ok = Digest.flush(kim.email, @window, "tenant_a", now: later())

    assert [%{subject: "2 updates", to: to, html_body: html}] = sent_emails()
    assert to == kim.email
    assert html =~ "Moved to 10:00"
    assert html =~ "Room 4"

    by_id = Map.new(receipts("tenant_a"), &{&1.id, &1})
    [digest] = Enum.filter(Map.values(by_id), &(&1.event_id == "ash_dispatch.digest"))

    assert digest.status == :sent
    assert digest.__meta__.prefix == "tenant_a"
    assert by_id[first.id].status == :digested
    assert by_id[second.id].status == :digested
    assert by_id[first.id].content["digest"]["receipt_id"] == digest.id

    # tenant_b's email for the same address waits in tenant_b.
    assert [%{id: id, status: :batched}] = receipts("tenant_b")
    assert id == other.id
  end

  test "a renderer's {name, email} sender survives the JSONB column" do
    defmodule TupleRenderer do
      @moduledoc false
      @behaviour AshDispatch.DigestRenderer

      @impl true
      def render(items, _info) do
        %{
          subject: "Digest of #{length(items)}",
          html_body: "<p>digest</p>",
          text_body: "digest",
          from: {"Projects", "projects@example.com"}
        }
      end
    end

    Application.put_env(:ash_dispatch, :digest_renderer, TupleRenderer)
    on_exit(fn -> Application.delete_env(:ash_dispatch, :digest_renderer) end)

    kim = user("kim")
    batch!("tenant_a", %{recipient: kim.email, user_id: kim.id})
    batch!("tenant_a", %{recipient: kim.email, user_id: kim.id})

    assert :ok = Digest.flush(kim.email, @window, "tenant_a", now: later())

    assert [%{subject: "Digest of 2", from: {"Projects", "projects@example.com"}}] = sent_emails()
  end

  test "a second flush finds nothing: no email is in two digests" do
    kim = user("kim")
    batch!("tenant_a", %{recipient: kim.email, user_id: kim.id})
    batch!("tenant_a", %{recipient: kim.email, user_id: kim.id})

    assert :ok = Digest.flush(kim.email, @window, "tenant_a", now: later())
    assert :ok = Digest.flush(kim.email, @window, "tenant_a", now: later())

    assert length(sent_emails()) == 1

    assert receipts("tenant_a")
           |> Enum.filter(&(&1.event_id == "ash_dispatch.digest"))
           |> length() ==
             1
  end

  test "a lone email goes out as itself through the real transitions" do
    kim = user("kim")
    receipt = batch!("tenant_a", %{recipient: kim.email, user_id: kim.id, subject: "Only one"})

    assert :ok = Digest.flush(kim.email, @window, "tenant_a", now: later())

    assert [%{subject: "Only one"}] = sent_emails()
    assert [%{id: id, status: :sent}] = receipts("tenant_a")
    assert id == receipt.id
  end

  test "send now on a waiting email sends it on its own" do
    kim = user("kim")
    receipt = batch!("tenant_a", %{recipient: kim.email, user_id: kim.id, subject: "Now please"})

    receipt
    |> Ash.Changeset.for_update(:send_now, %{})
    |> Ash.Changeset.set_tenant("tenant_a")
    |> Ash.update!(authorize?: false)

    assert [%{subject: "Now please"}] = sent_emails()
    assert [%{status: :sent}] = receipts("tenant_a")

    # The flush that comes later has nothing left to send.
    assert :ok = Digest.flush(kim.email, @window, "tenant_a", now: later())
    assert sent_emails() == []
  end

  test "the sweep of one tenant sends that tenant's due groups only" do
    kim = user("kim")
    batch!("tenant_a", %{recipient: kim.email, user_id: kim.id})
    batch!("tenant_b", %{recipient: kim.email, user_id: kim.id})

    assert :ok = Digest.sweep("tenant_a", now: later())

    assert length(sent_emails()) == 1
    assert [%{status: :sent}] = receipts("tenant_a")
    assert [%{status: :batched}] = receipts("tenant_b")
  end
end
