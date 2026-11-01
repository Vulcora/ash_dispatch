defmodule AshDispatch.Transports.EmailSensitiveArgsTest do
  # Async disabled: reads Application config for event discovery
  use ExUnit.Case, async: false

  alias AshDispatch.Channel
  alias AshDispatch.Context
  alias AshDispatch.Transports.Email
  alias AshDispatch.Workers.SendEmail

  import ExUnit.CaptureLog

  @moduletag :capture_log

  @secret "https://example.com/reset/s3cr3t-token"

  setup do
    original = Application.get_env(:ash_dispatch, :otp_app)
    Application.put_env(:ash_dispatch, :otp_app, :ash_dispatch_test)

    on_exit(fn ->
      if original,
        do: Application.put_env(:ash_dispatch, :otp_app, original),
        else: Application.delete_env(:ash_dispatch, :otp_app)
    end)

    :ok
  end

  defp receipt do
    %{
      id: Ecto.UUID.generate(),
      recipient: "user@example.com",
      subject: "Your code",
      body_html: "<a href=\"#{@secret}\">Reset</a>",
      body_text: "Reset: #{@secret}",
      content: %{
        from: %{"name" => "App", "email" => "app@example.com"},
        reply_to: "help@example.com",
        html_body: "<a href=\"#{@secret}\">Reset</a>",
        text_body: "Reset: #{@secret}"
      }
    }
  end

  defp args(receipt, event_id) do
    receipt
    |> Email.job_args(%Context{event_id: event_id}, %Channel{transport: :email, audience: :user})
    |> Jason.encode!()
    |> Jason.decode!()
  end

  test "a sensitive event's job args carry only the receipt id, the event id and attachments" do
    assert Email.sensitive?("ticket.otp_issued")

    args = args(receipt(), "ticket.otp_issued")

    assert args |> Map.keys() |> Enum.sort() == ["attachments", "event_id", "receipt_id"]
    refute Jason.encode!(args) =~ "s3cr3t-token"
  end

  test "a sensitive event's attachments stay in the args, as documented" do
    Application.put_env(:ash_dispatch, :default_email_attachments, fn ->
      [%{filename: "logo.png", content_type: "image/png", data: "bytes"}]
    end)

    on_exit(fn -> Application.delete_env(:ash_dispatch, :default_email_attachments) end)

    assert [%{"filename" => "logo.png", "data" => data}] =
             args(receipt(), "ticket.otp_issued")["attachments"]

    assert Base.decode64!(data) == "bytes"
  end

  test "the worker still sends a sensitive event's full envelope, read from the receipt" do
    receipt = receipt()
    params = SendEmail.email_params(receipt, args(receipt, "ticket.otp_issued"))

    assert params.to == "user@example.com"
    assert params.subject == "Your code"
    assert params.from == {"App", "app@example.com"}
    assert params.reply_to == "help@example.com"
    assert params.html_body =~ "s3cr3t-token"
    assert params.text_body =~ "s3cr3t-token"
  end

  test "an ordinary event keeps its rendered bodies in the args" do
    refute Email.sensitive?("ticket.created")

    args = args(receipt(), "ticket.created")

    assert args["html_body"] =~ "s3cr3t-token"
    assert args["text_body"] =~ "s3cr3t-token"
    assert args["subject"] == "Your code"
  end

  test "an event the registry cannot find is reported: the protection did not apply" do
    assert capture_log([level: :warning], fn -> refute Email.sensitive?("no.such.event") end) =~
             "no.such.event"
  end

  test "a known event is not reported" do
    assert capture_log(fn -> Email.sensitive?("ticket.created") end) == ""
  end

  test "an unknown event is not sensitive and keeps the full args" do
    refute Email.sensitive?("no.such.event")
    assert args(receipt(), "no.such.event")["html_body"]
  end
end
