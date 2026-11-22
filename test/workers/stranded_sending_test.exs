defmodule AshDispatch.Workers.StrandedSendingTest do
  @moduledoc """
  `:sending` was a dead end: a node that went down between `mark_sending` and
  the provider left the receipt there, no transition led out, and neither the
  retry sweep (`:failed`) nor the stranded sweep (`:scheduled`) looked. The
  message was gone and nothing said so.

  Three halves are pinned here:

  1. `AshDispatch.ReceiptStatus.claim/2` — the mutex still holds for a
     duplicate job, and this job's own interrupted attempt reclaims.
  2. `AshDispatch.Workers.Stranded.sending_action/3` — the decision, and that
     it leaves `:sending` alone unless a host asks.
  3. The sweep — off by default, and honest under each mode.

  The sweep's tests travel `AshDispatch.Clock` rather than back-dating a row:
  no action accepts a timestamp, and the clock is the mechanism the library
  already has for exactly this.
  """
  # Not async: every test here configures :ash_dispatch, which is global.
  use ExUnit.Case, async: false

  alias AshDispatch.ReceiptStatus
  alias AshDispatch.Test.StrictReceipt
  alias AshDispatch.Test.TransportReceipt
  alias AshDispatch.Workers.RetryFailedDeliveries
  alias AshDispatch.Workers.Stranded

  @moduletag :capture_log

  @now ~U[2026-11-20 09:00:00Z]

  # Every test in this file may set it, directly or in a loop, and tests here
  # share one process: restored once, for all of them.
  setup do
    previous = Application.fetch_env(:ash_dispatch, :stranded_sending)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:ash_dispatch, :stranded_sending, old)
        :error -> Application.delete_env(:ash_dispatch, :stranded_sending)
      end
    end)

    :ok
  end

  defmodule Frozen do
    @moduledoc false
    use Agent

    def start_link(at), do: Agent.start_link(fn -> at end, name: __MODULE__)
    def utc_now, do: Agent.get(__MODULE__, & &1)
    def travel(to), do: Agent.update(__MODULE__, fn _ -> to end)
  end

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

  defp receipt!(resource, status) do
    resource
    |> Ash.Changeset.for_create(:create, %{
      status: status,
      event_id: "ticket.created",
      transport: :email,
      recipient: "user@example.com",
      subject: "Hello",
      body_text: "Hello there",
      content: %{}
    })
    |> Ash.create!(authorize?: false)
  end

  defp status(resource, receipt) do
    Ash.get!(resource, receipt.id, authorize?: false).status
  end

  describe "ReceiptStatus.claim/2 keeps the mutex" do
    test "a first attempt on a :sending receipt is somebody else's work" do
      receipt = receipt!(StrictReceipt, :sending)

      assert :duplicate = ReceiptStatus.claim(receipt, attempt: 1)
      assert status(StrictReceipt, receipt) == :sending
    end

    test "a job without an attempt counter is read as a first attempt" do
      receipt = receipt!(StrictReceipt, :sending)

      assert :duplicate = ReceiptStatus.claim(receipt, [])
    end

    test "a later attempt on a :sending receipt reclaims it" do
      receipt = receipt!(StrictReceipt, :sending)

      assert {:ok, claimed} = ReceiptStatus.claim(receipt, attempt: 2)
      assert claimed.status == :sending
    end

    test ":resume forces the answer either way" do
      receipt = receipt!(StrictReceipt, :sending)

      assert :duplicate = ReceiptStatus.claim(receipt, attempt: 9, resume: false)
      assert {:ok, _} = ReceiptStatus.claim(receipt, attempt: 1, resume: true)
    end

    test "a scheduled receipt is claimed on any attempt, as it always was" do
      receipt = receipt!(StrictReceipt, :scheduled)

      assert {:ok, claimed} = ReceiptStatus.claim(receipt, attempt: 1)
      assert claimed.status == :sending
    end

    test "a terminal receipt is still refused as a duplicate" do
      receipt = receipt!(StrictReceipt, :sent)

      assert :duplicate = ReceiptStatus.claim(receipt, attempt: 4)
      assert status(StrictReceipt, receipt) == :sent
    end

    test "an UNEXPECTED resume failure propagates — the letter is not sent" do
      # Only two causes may answer `{:ok, receipt}`: no `:resume_sending`
      # action at all, and a host that narrowed the transition. Anything else
      # — a validation the host added, a write the database refused — is a
      # failure, and answering `{:ok, receipt}` to it would send the letter
      # with the receipt left saying something else.
      receipt = receipt!(StrictReceipt, :sending)
      broken = %{receipt | __struct__: AshDispatch.Test.RefusingReceipt}

      assert {:error, _} = ReceiptStatus.claim(broken, attempt: 2)
    end

    test "a host that narrowed the transition still gets its send" do
      # `NoMatchingTransition` is the documented second cause: the receipt is
      # already `:sending` and this attempt owns it.
      receipt = receipt!(AshDispatch.Test.NarrowedReceipt, :sending)

      assert {:ok, claimed} = ReceiptStatus.claim(receipt, attempt: 2)
      assert claimed.id == receipt.id
    end

    test "a receipt resource without :resume_sending still resumes" do
      # Every host's receipt resource built before 0.9.4. The receipt is
      # already `:sending`, so the attempt owns it and delivers from it — which
      # is exactly what 0.9.2 did for email.
      refute Ash.Resource.Info.action(TransportReceipt, :resume_sending)

      receipt = receipt!(TransportReceipt, :sending)

      assert {:ok, claimed} = ReceiptStatus.claim(receipt, attempt: 2)
      assert claimed.id == receipt.id
    end
  end

  describe "ReceiptStatus.resume_sending/1" do
    test "re-enters :sending" do
      receipt = receipt!(StrictReceipt, :sending)

      assert {:ok, resumed} = ReceiptStatus.resume_sending(receipt)
      assert resumed.status == :sending
    end

    test "moves updated_at, which is the age the stranded sweep reads" do
      # The whole reason the transition re-enters the same state rather than
      # doing nothing: without a fresh `updated_at` a resumed send looks
      # equally stranded on the next sweep and is rescued or closed under it.
      receipt = receipt!(StrictReceipt, :sending)
      Process.sleep(10)

      assert {:ok, resumed} = ReceiptStatus.resume_sending(receipt)

      assert DateTime.compare(resumed.updated_at, receipt.updated_at) == :gt,
             "resume_sending did not move updated_at; the sweep's age reference is stale"
    end

    test "refuses a receipt that is not :sending" do
      receipt = receipt!(StrictReceipt, :scheduled)

      assert {:error, _} = ReceiptStatus.resume_sending(receipt)
    end

    test "answers :unsupported for a resource that has no such action" do
      receipt = receipt!(TransportReceipt, :sending)

      assert {:error, :unsupported} = ReceiptStatus.resume_sending(receipt)
    end
  end

  describe "Stranded.sending_action/3" do
    defp sending_fate(seconds_ago, mode) do
      Stranded.sending_action(DateTime.add(@now, -seconds_ago, :second), mode, now: @now)
    end

    test ":ignore is the default and leaves everything alone" do
      assert Stranded.default_sending_mode() == :ignore
      assert Stranded.sending_mode() == :ignore
      assert sending_fate(3 * 3600, nil) == :leave
      assert sending_fate(48 * 3600, nil) == :leave
    end

    test "the grace period holds under every mode: a live send is not a loss" do
      assert sending_fate(5, :close) == :leave
      assert sending_fate(5, :rescue) == :leave
      assert sending_fate(30 * 60 - 1, :rescue) == :leave
    end

    test ":close never resends — past the grace period it closes" do
      assert sending_fate(30 * 60, :close) == :close
      assert sending_fate(3 * 3600, :close) == :close
      assert sending_fate(48 * 3600, :close) == :close
    end

    test ":rescue hands it back, and still closes past the staleness ceiling" do
      assert sending_fate(3 * 3600, :rescue) == :rescue
      assert sending_fate(48 * 3600, :rescue) == :close
    end

    test "an unknown mode sweeps nothing, and says so once per sweep" do
      Stranded.forget_warning()

      assert sending_fate(48 * 3600, :resend_everything) == :leave

      # Once per sweep, not once per receipt: a hundred stranded receipts are
      # one line, and a host that does not fix it sees one line a pass.
      log = ExUnit.CaptureLog.capture_log(fn -> sending_fate(48 * 3600, :nonsense) end)
      refute log =~ "stranded_sending"

      Stranded.forget_warning()
      log = ExUnit.CaptureLog.capture_log(fn -> sending_fate(48 * 3600, :nonsense) end)
      assert log =~ "stranded_sending"
    end

    test ":rescue closes a receipt whose retry budget is spent" do
      # `:rescue` hands a receipt to machinery that only looks at receipts
      # with retries LEFT. One whose budget is spent would sit in `:failed`
      # and be swept back here every pass, for ever, with the books saying it
      # will be retried.
      opts = [now: @now, retry_count: 5, max_retries: 5]

      assert Stranded.sending_action(DateTime.add(@now, -3 * 3600, :second), :rescue, opts) ==
               :close
    end

    test "and hands over one that still has retries" do
      opts = [now: @now, retry_count: 2, max_retries: 5]

      assert Stranded.sending_action(DateTime.add(@now, -3 * 3600, :second), :rescue, opts) ==
               :rescue
    end

    test "a budget nobody mentioned is not treated as spent" do
      assert sending_fate(3 * 3600, :rescue) == :rescue
    end

    test "the close reason says the outcome is unknown, not that it failed" do
      reason =
        Stranded.sending_close_reason(DateTime.add(@now, -48 * 3600, :second), now: @now)

      assert reason =~ "48h"
      assert reason =~ ":sending"
      assert reason =~ "unknown"
      refute reason =~ "nil"
    end

    test "the rescue reason admits it may be a second send" do
      assert Stranded.sending_rescue_reason() =~ "second send"
    end
  end

  describe "the sweep" do
    setup do
      # Frozen at the real now, not at `@now`: `inserted_at`/`updated_at` are
      # deliberately NOT on the clock (see `AshDispatch.Clock`), so a receipt
      # created here carries real wall-clock time and the clock has to start
      # beside it for the ages to mean anything.
      started = DateTime.utc_now()
      start_supervised!({Frozen, started})
      put_env(:clock, {Frozen, :utc_now, []})
      put_env(:delivery_receipt_resource, StrictReceipt)

      {:ok, started: started}
    end

    # An hour on from the receipt's own `updated_at`: past the 30-minute grace
    # period, well inside the 24-hour ceiling.
    defp strand(started), do: Frozen.travel(DateTime.add(started, 3600, :second))

    test "does not look at :sending by default", %{started: started} do
      receipt = receipt!(StrictReceipt, :sending)
      strand(started)

      assert :ok = RetryFailedDeliveries.sweep_stranded()
      assert status(StrictReceipt, receipt) == :sending
    end

    test "closes a stranded :sending receipt under :close", %{started: started} do
      put_env(:stranded_sending, :close)
      receipt = receipt!(StrictReceipt, :sending)
      strand(started)

      assert :ok = RetryFailedDeliveries.sweep_stranded()
      assert status(StrictReceipt, receipt) == :failed_permanent

      closed = Ash.get!(StrictReceipt, receipt.id, authorize?: false)
      assert closed.error_message =~ "unknown"
    end

    test "hands a stranded :sending receipt to the retry machinery under :rescue", %{
      started: started
    } do
      put_env(:stranded_sending, :rescue)
      receipt = receipt!(StrictReceipt, :sending)
      strand(started)

      assert :ok = RetryFailedDeliveries.sweep_stranded()
      assert status(StrictReceipt, receipt) == :failed
    end

    test "leaves a send that is merely in progress, under either mode" do
      for mode <- [:close, :rescue] do
        Application.put_env(:ash_dispatch, :stranded_sending, mode)
        receipt = receipt!(StrictReceipt, :sending)

        assert :ok = RetryFailedDeliveries.sweep_stranded()
        assert status(StrictReceipt, receipt) == :sending
      end
    end

    test "still sweeps :scheduled exactly as before, whatever the :sending mode", %{
      started: started
    } do
      for mode <- [nil, :close, :rescue] do
        if mode,
          do: Application.put_env(:ash_dispatch, :stranded_sending, mode),
          else: Application.delete_env(:ash_dispatch, :stranded_sending)

        receipt = receipt!(StrictReceipt, :scheduled)
        strand(started)

        assert :ok = RetryFailedDeliveries.sweep_stranded()
        assert status(StrictReceipt, receipt) == :failed
      end
    end
  end
end
