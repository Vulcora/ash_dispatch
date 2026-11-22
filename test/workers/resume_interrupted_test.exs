defmodule AshDispatch.Workers.ResumeInterruptedTest do
  @moduledoc """
  Which workers reclaim a receipt their own earlier attempt left in `:sending`
  — and, more to the point, which ones did NOT before 0.9.4.

  `SendEmail` has resumed since 0.9.2. `SendSMS` logged "likely duplicate job"
  and answered `:ok` without sending. `SendWebhook` raised a MatchError and
  never POSTed. Giving all three the shared `claim/2` gave SMS and webhook a
  behaviour they never had, so a host that upgraded and changed nothing could
  get a duplicate text message or a second Slack post. A patch may not do
  that.

  Each is a setting now, defaulting to what that worker already did.
  """
  # Not async: configures :ash_dispatch, which is global
  use ExUnit.Case, async: false

  alias AshDispatch.Config
  alias AshDispatch.Test.StrictReceipt
  alias AshDispatch.Workers.SendSMS

  @moduletag :capture_log

  defmodule Backend do
    @moduledoc false
    @behaviour AshDispatch.SMSBackend

    @impl true
    def deliver(receipt, _context, _channel, _opts) do
      send(self(), {:sms_sent, receipt.id})
      {:ok, AshDispatch.ReceiptStatus.mark_sent(receipt, %{id: "prov-1"})}
    end
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

  setup do
    put_env(:delivery_receipt_resource, StrictReceipt)
    put_env(:sms_backend, Backend)
    put_env(:skip_email_delivery, false)
    :ok
  end

  defp receipt!(status) do
    # `StrictReceipt`, not `TransportReceipt`: the stand-in without a state
    # machine lets any action run from any state, so the mutex this test is
    # about does not exist there.
    StrictReceipt
    |> Ash.Changeset.for_create(:create, %{
      status: status,
      event_id: "ticket.created",
      transport: :sms,
      recipient: "+46701234567",
      content: %{"message" => "Code 1234"}
    })
    |> Ash.create!(authorize?: false)
  end

  describe "the defaults are what each worker already did" do
    test "email resumes, as it has since 0.9.2" do
      assert Config.resume_interrupted?(:email) == true
    end

    test "SMS does not, because before 0.9.4 it sent nothing" do
      assert Config.resume_interrupted?(:sms) == false
    end

    test "nor does the webhook worker, which raised and never POSTed" do
      assert Config.resume_interrupted?(:webhook) == false
      # Slack and Discord share that worker.
      assert Config.resume_interrupted?(:slack) == false
      assert Config.resume_interrupted?(:discord) == false
    end

    test "a transport nobody named does not resume" do
      assert Config.resume_interrupted?(:carrier_pigeon) == false
    end
  end

  describe "SendSMS on a receipt its own earlier attempt left in :sending" do
    test "sends nothing by default — no second text message" do
      receipt = receipt!(:sending)

      assert :ok = SendSMS.perform(%Oban.Job{args: %{"receipt_id" => receipt.id}, attempt: 2})

      refute_received {:sms_sent, _}
    end

    test "and sends when the host asks for it" do
      put_env(:sms_resume_interrupted, true)
      receipt = receipt!(:sending)

      assert :ok = SendSMS.perform(%Oban.Job{args: %{"receipt_id" => receipt.id}, attempt: 2})

      assert_received {:sms_sent, _}
    end

    test "a first attempt never resumes, whatever the setting" do
      put_env(:sms_resume_interrupted, true)
      receipt = receipt!(:sending)

      assert :ok = SendSMS.perform(%Oban.Job{args: %{"receipt_id" => receipt.id}, attempt: 1})

      refute_received {:sms_sent, _}
    end
  end

  describe "what did not change for SMS" do
    test "a scheduled receipt is sent on the first attempt" do
      receipt = receipt!(:scheduled)

      assert :ok = SendSMS.perform(%Oban.Job{args: %{"receipt_id" => receipt.id}, attempt: 1})

      assert_received {:sms_sent, _}
    end

    test "a receipt already sent is never sent again" do
      receipt = receipt!(:sent)

      assert :ok = SendSMS.perform(%Oban.Job{args: %{"receipt_id" => receipt.id}, attempt: 3})

      refute_received {:sms_sent, _}
    end
  end
end
