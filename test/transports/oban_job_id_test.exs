defmodule AshDispatch.Transports.ObanJobIdTest do
  @moduledoc """
  Every transport that enqueues a job records which job it is.

  The stranded sweep reads the job's state before it decides anything
  (`AshDispatch.Workers.Stranded`), and it finds the job through the receipt's
  `oban_job_id`. Email and SMS have always written it; the webhook, Slack and
  Discord transports never did, so for those three the gate was inert and the
  sweep fell back on age alone — which is exactly how it could close a receipt
  whose job Oban was about to rescue.

  Those three mark the receipt `:scheduled` BEFORE inserting the job (an
  inline job runs inside `Oban.insert/1` and would race the transition), so
  the id can only be written afterwards.

  Postgres-backed, with Oban's own engine and a real `oban_jobs` table, for a
  blunt reason: `Oban.Engines.Inline` never assigns an id (`id: nil`), so the
  one thing this file is about cannot be observed under it.
  """
  use ExUnit.Case, async: false

  alias AshDispatch.Channel
  alias AshDispatch.Context
  alias AshDispatch.ReceiptStatus
  alias AshDispatch.Test.PerTenant
  alias AshDispatch.Test.TransportReceipt

  @moduletag :postgres
  @moduletag :capture_log

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

  setup do
    start_supervised!(
      {PerTenant.Repo, url: System.fetch_env!("ASH_DISPATCH_TEST_DATABASE_URL"), pool_size: 4}
    )

    # Oban's own table, so a job gets a real id. Through the migrator with
    # `all: true` and the version record cleared, because `Ecto.Migrator.up/4`
    # is a no-op for a version `schema_migrations` already holds — and this
    # setup runs once per test.
    PerTenant.Repo.query!("drop table if exists oban_jobs cascade")
    PerTenant.Repo.query!("drop type if exists oban_job_state cascade")

    PerTenant.Repo.query!(
      "create table if not exists schema_migrations (version bigint primary key, inserted_at timestamp)"
    )

    PerTenant.Repo.query!("delete from schema_migrations where version = 0")

    Ecto.Migrator.run(PerTenant.Repo, [{0, AshDispatch.Test.ObanMigration}], :up,
      all: true,
      log: false
    )

    put_env(:delivery_receipt_resource, TransportReceipt)
    put_env(:repo, PerTenant.Repo)

    Application.put_env(:ash_dispatch, AshDispatch.Workers.SendWebhook,
      req_options: [plug: {Req.Test, __MODULE__}]
    )

    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{"ok" => true}) end)

    on_exit(fn -> Application.delete_env(:ash_dispatch, AshDispatch.Workers.SendWebhook) end)

    start_supervised!(
      {Oban,
       name: Oban,
       repo: PerTenant.Repo,
       notifier: {Oban.Notifiers.Isolated, []},
       peer: {Oban.Peers.Isolated, [leader?: false]},
       plugins: [],
       queues: [],
       stager: false}
    )

    :ok
  end

  defp receipt!(transport) do
    TransportReceipt
    |> Ash.Changeset.for_create(:create, %{
      status: :pending,
      event_id: "ticket.created",
      transport: transport,
      audience: :team,
      recipient: "https://hooks.example.test/abc",
      content: %{"message" => "hello", "notification_message" => "hello"}
    })
    |> Ash.create!(authorize?: false)
  end

  defp reload(receipt), do: Ash.get!(TransportReceipt, receipt.id, authorize?: false)

  defp context do
    %Context{event_id: "ticket.created", data: %{}, variables: %{}, metadata: %{}}
  end

  describe "ReceiptStatus.put_oban_job_id/2" do
    test "records the id without moving the state" do
      receipt = receipt!(:webhook)

      updated = ReceiptStatus.put_oban_job_id(receipt, 4711)

      assert updated.oban_job_id == 4711
      assert updated.status == :pending
      assert reload(receipt).oban_job_id == 4711
    end

    test "nil is a no-op, not a write of nil" do
      receipt = ReceiptStatus.put_oban_job_id(receipt!(:webhook), 99)

      assert ReceiptStatus.put_oban_job_id(receipt, nil).oban_job_id == 99
    end

    test "never raises: a receipt that cannot take the id is returned as it was" do
      orphan = struct(TransportReceipt, id: Ecto.UUID.generate(), status: :pending)

      assert ReceiptStatus.put_oban_job_id(orphan, 1).id == orphan.id
    end
  end

  describe "the transports that mark scheduled before inserting" do
    for {transport, module} <- [
          {:webhook, AshDispatch.Transports.Webhook},
          {:slack, AshDispatch.Transports.Slack},
          {:discord, AshDispatch.Transports.Discord}
        ] do
      test "#{transport} records its job id, so the sweep can find the job" do
        transport = unquote(transport)
        module = unquote(module)

        receipt = receipt!(transport)

        channel = %Channel{
          transport: transport,
          audience: :team,
          webhook_url: "https://hooks.example.test/abc"
        }

        module.deliver(receipt, context(), channel, %{})

        job_id = reload(receipt).oban_job_id

        assert job_id, "#{transport} enqueued a job and did not record which one"

        # And it is a job that exists: the whole point is that the sweep can
        # read its state.
        assert %{rows: [[state]]} =
                 PerTenant.Repo.query!("select state from oban_jobs where id = $1", [job_id])

        assert state in ~w(available scheduled executing retryable completed)
      end
    end

    test "email still records it, as it always has" do
      # The two that were never broken, so the fix cannot have moved them.
      assert Ash.Resource.Info.action(TransportReceipt, :schedule).accept == [:oban_job_id]
    end
  end
end
