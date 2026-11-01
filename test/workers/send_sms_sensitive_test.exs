defmodule AshDispatch.Workers.SendSMSSensitiveTest do
  @moduledoc """
  The same fail-closed rule as `SendEmail`: a sensitive event whose receipt has
  no text left never reaches the backend. The scrub removes the text from
  `content`, so a reopened receipt would otherwise go out empty, or as the marker.
  """
  # Async disabled: configures :ash_dispatch for the receipt resource and backend
  use ExUnit.Case, async: false

  alias AshDispatch.Test.TransportReceipt
  alias AshDispatch.Workers.ScrubSensitiveContent
  alias AshDispatch.Workers.SendSMS

  @moduletag :capture_log

  defmodule Backend do
    def deliver(receipt, _context, _channel, _event_config) do
      send(self(), {:backend_called, receipt})

      {:ok,
       receipt
       |> Ash.Changeset.for_update(:mark_sent, %{})
       |> Ash.update!(authorize?: false)}
    end
  end

  setup do
    env = [:otp_app, :delivery_receipt_resource, :sms_backend]
    saved = for key <- env, do: {key, Application.get_env(:ash_dispatch, key)}

    Application.put_env(:ash_dispatch, :otp_app, :ash_dispatch_test)
    Application.put_env(:ash_dispatch, :delivery_receipt_resource, TransportReceipt)
    Application.put_env(:ash_dispatch, :sms_backend, Backend)

    on_exit(fn ->
      for {key, value} <- saved do
        if is_nil(value),
          do: Application.delete_env(:ash_dispatch, key),
          else: Application.put_env(:ash_dispatch, key, value)
      end
    end)

    :ok
  end

  defp receipt!(attrs) do
    TransportReceipt
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          status: :scheduled,
          event_id: "ticket.otp_issued",
          transport: :sms,
          recipient: "+46700000000"
        },
        attrs
      )
    )
    |> Ash.create!(authorize?: false)
  end

  defp perform(receipt) do
    SendSMS.perform(%Oban.Job{args: %{"receipt_id" => receipt.id}})
  end

  defp status(receipt), do: Ash.get!(TransportReceipt, receipt.id, authorize?: false).status

  defp assert_refused(receipt) do
    assert {:cancel, _reason} = perform(receipt)
    refute_received {:backend_called, _}
    assert status(receipt) == :failed_permanent
  end

  test "a scrubbed receipt is never sent" do
    assert_refused(receipt!(%{body_text: ScrubSensitiveContent.marker(), content: %{}}))
  end

  test "a receipt with no text is never sent" do
    assert_refused(receipt!(%{content: %{}}))
  end

  test "the marker in the content is never sent" do
    assert_refused(receipt!(%{content: %{message: ScrubSensitiveContent.marker()}}))
  end

  test "a pending receipt is refused too" do
    assert_refused(receipt!(%{status: :pending, content: %{}}))
  end

  test "a sensitive event with its text is sent" do
    receipt = receipt!(%{content: %{message: "Your code is 123456"}})

    assert :ok = perform(receipt)
    assert_received {:backend_called, _}
  end

  test "the text survives JSONB: a string key is still the text" do
    receipt = receipt!(%{content: %{"body" => "Your code is 123456"}})

    assert :ok = perform(receipt)
    assert_received {:backend_called, _}
  end

  test "an ordinary event is not held to this" do
    receipt = receipt!(%{event_id: "ticket.created", content: %{}})

    assert :ok = perform(receipt)
    assert_received {:backend_called, _}
  end
end
