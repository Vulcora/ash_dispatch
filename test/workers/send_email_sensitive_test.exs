defmodule AshDispatch.Workers.SendEmailSensitiveTest do
  @moduledoc """
  A sensitive event's job carries no bodies, so the receipt is the only source
  of what gets sent. When the receipt no longer holds a body the worker must
  fail closed: nothing reaches the backend and the receipt is not `:sent`.
  """
  # Async disabled: configures :ash_dispatch for the receipt resource and backend
  use ExUnit.Case, async: false

  alias AshDispatch.Test.TransportReceipt
  alias AshDispatch.Workers.ScrubSensitiveContent
  alias AshDispatch.Workers.SendEmail

  @moduletag :capture_log

  @sensitive "ticket.otp_issued"
  @ordinary "ticket.created"

  defmodule Backend do
    def send_email(params) do
      send(self(), {:backend_called, params})
      {:ok, %{id: "provider-id"}}
    end
  end

  setup do
    env = [:otp_app, :delivery_receipt_resource, :email_backend, :skip_email_delivery]
    saved = for key <- env, do: {key, Application.get_env(:ash_dispatch, key)}

    Application.put_env(:ash_dispatch, :otp_app, :ash_dispatch_test)
    Application.put_env(:ash_dispatch, :delivery_receipt_resource, TransportReceipt)
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

  defp receipt!(attrs) do
    TransportReceipt
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          status: :scheduled,
          event_id: @sensitive,
          transport: :email,
          recipient: "user@example.com",
          subject: "Your code",
          content: %{}
        },
        attrs
      )
    )
    |> Ash.create!(authorize?: false)
  end

  defp perform(receipt, args \\ %{}) do
    SendEmail.perform(%Oban.Job{args: Map.put(args, "receipt_id", receipt.id)})
  end

  defp status(receipt), do: Ash.get!(TransportReceipt, receipt.id, authorize?: false).status

  defp assert_refused(receipt) do
    assert {:cancel, reason} = perform(receipt)
    assert is_binary(reason)
    refute_received {:backend_called, _}
    assert status(receipt) == :failed_permanent
  end

  describe "a sensitive event whose receipt has no body left" do
    test "the scrub's marker is never sent" do
      assert_refused(receipt!(%{body_text: ScrubSensitiveContent.marker(), body_html: nil}))
    end

    test "missing bodies are never sent" do
      assert_refused(receipt!(%{body_text: nil, body_html: nil}))
    end

    test "empty bodies are never sent" do
      assert_refused(receipt!(%{body_text: "", body_html: ""}))
    end

    test "a pending receipt is refused too" do
      assert_refused(receipt!(%{status: :pending, body_text: nil, body_html: nil}))
    end
  end

  describe "what is still sent" do
    test "a sensitive event with its body, read from the receipt" do
      receipt = receipt!(%{body_text: "Reset: token", body_html: "<a>token</a>"})

      assert :ok = perform(receipt)
      assert_received {:backend_called, %{text_body: "Reset: token"}}
      assert status(receipt) == :sent
    end

    test "a sensitive event with only an html body" do
      receipt = receipt!(%{body_text: nil, body_html: "<a>token</a>"})

      assert :ok = perform(receipt)
      assert_received {:backend_called, %{html_body: "<a>token</a>"}}
    end

    test "a job enqueued before 0.8.7 still sends the bodies in its args" do
      receipt = receipt!(%{body_text: nil, body_html: nil})

      assert :ok = perform(receipt, %{"text_body" => "from the job"})
      assert_received {:backend_called, %{text_body: "from the job"}}
    end

    test "an ordinary event is not held to this" do
      receipt = receipt!(%{event_id: @ordinary, body_text: nil, body_html: nil})

      assert :ok = perform(receipt)
      assert_received {:backend_called, _}
    end
  end
end
