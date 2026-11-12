defmodule AshDispatch.Workers.SendEmailInterruptedTest do
  @moduledoc """
  A job that marked its receipt `:sending` and then stopped without a result -
  the node went down, or Oban's lifeline rescued an orphaned job - must send
  when it runs again. Before 0.9.2 the second run read `:sending` as "another
  job has this" and completed successfully without sending: the email was lost
  and the receipt stayed in `:sending` for good.
  """
  # Async disabled: configures :ash_dispatch for the receipt resource and backend
  use ExUnit.Case, async: false

  alias AshDispatch.Test.Setup.Deliveries.DeliveryReceipt, as: RealReceipt
  alias AshDispatch.Test.StrictReceipt
  alias AshDispatch.Workers.SendEmail

  @moduletag :capture_log

  defmodule Backend do
    def send_email(params) do
      send(self(), {:backend_called, params})

      case Process.get(:backend_reply) do
        nil -> {:ok, %{id: "provider-id"}}
        reply -> reply
      end
    end
  end

  setup do
    env = [:otp_app, :delivery_receipt_resource, :email_backend, :skip_email_delivery]
    saved = for key <- env, do: {key, Application.get_env(:ash_dispatch, key)}

    Application.put_env(:ash_dispatch, :otp_app, :ash_dispatch_test)
    Application.put_env(:ash_dispatch, :delivery_receipt_resource, StrictReceipt)
    Application.put_env(:ash_dispatch, :email_backend, Backend)
    Application.put_env(:ash_dispatch, :skip_email_delivery, false)

    on_exit(fn ->
      for {key, value} <- saved do
        if is_nil(value),
          do: Application.delete_env(:ash_dispatch, key),
          else: Application.put_env(:ash_dispatch, key, value)
      end
    end)

    :ok
  end

  defp receipt!(status) do
    StrictReceipt
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

  defp perform(receipt, attempt) do
    SendEmail.perform(%Oban.Job{args: %{"receipt_id" => receipt.id}, attempt: attempt})
  end

  defp status(receipt), do: Ash.get!(StrictReceipt, receipt.id, authorize?: false).status

  test "the stand-in refuses the same transitions as the real receipt" do
    sources = fn resource, action ->
      resource
      |> AshStateMachine.Info.state_machine_transitions()
      |> Enum.filter(&(&1.action == action))
      |> Enum.flat_map(&List.wrap(&1.from))
      |> Enum.sort()
    end

    for action <- [:mark_sending, :mark_sent, :mark_failed] do
      assert sources.(StrictReceipt, action) == sources.(RealReceipt, action),
             "#{action} differs between the stand-in and DeliveryReceipt.Base"
    end
  end

  describe "a receipt left in :sending by an earlier attempt of the same job" do
    test "is sent when the job runs again, and ends up :sent" do
      receipt = receipt!(:sending)

      assert :ok = perform(receipt, 2)
      assert_received {:backend_called, %{to: "user@example.com"}}
      assert status(receipt) == :sent
    end

    test "is sent on any later attempt, not only the second" do
      receipt = receipt!(:sending)

      assert :ok = perform(receipt, 5)
      assert_received {:backend_called, _}
      assert status(receipt) == :sent
    end

    test "that fails again is marked failed, so the retry path takes over" do
      receipt = receipt!(:sending)
      Process.put(:backend_reply, {:error, :timeout})

      assert {:error, :timeout} = perform(receipt, 2)
      assert_received {:backend_called, _}
      assert status(receipt) == :failed
    end
  end

  describe "a receipt in :sending on a job's first attempt" do
    test "belongs to another job: nothing is sent and the state is left alone" do
      receipt = receipt!(:sending)

      assert :ok = perform(receipt, 1)
      refute_received {:backend_called, _}
      assert status(receipt) == :sending
    end
  end

  describe "what did not change" do
    test "a scheduled receipt is sent on the first attempt" do
      receipt = receipt!(:scheduled)

      assert :ok = perform(receipt, 1)
      assert_received {:backend_called, _}
      assert status(receipt) == :sent
    end

    test "a receipt already sent is never sent again, whatever the attempt" do
      receipt = receipt!(:sent)

      assert :ok = perform(receipt, 3)
      refute_received {:backend_called, _}
      assert status(receipt) == :sent
    end

    test "a job struct without an attempt behaves as a first attempt" do
      receipt = receipt!(:sending)

      assert :ok = SendEmail.perform(%Oban.Job{args: %{"receipt_id" => receipt.id}})
      refute_received {:backend_called, _}
    end
  end
end
