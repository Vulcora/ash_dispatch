defmodule AshDispatch.Workers.SendEmailTest do
  @moduledoc """
  Tests for the SendEmail worker.

  These tests verify that the worker correctly handles various email address formats
  (strings, tuples, maps, lists) without crashing, and that the attachment args
  written by `AshDispatch.Transports.Email` survive the JSONB round-trip.
  """
  # Async disabled: the attachment round-trip configures :otp_app for event discovery
  use ExUnit.Case, async: false

  alias AshDispatch.Channel
  alias AshDispatch.Context
  alias AshDispatch.Transports.Email
  alias AshDispatch.Workers.SendEmail

  # We can't test private functions directly, but we can test the module's
  # behavior by examining what formats it accepts. The parse_from_field logic
  # is tested indirectly via the email backend tests.

  describe "module compilation" do
    test "module compiles and is available" do
      assert Code.ensure_loaded?(AshDispatch.Workers.SendEmail)
    end

    test "implements Oban.Worker behaviour" do
      behaviours = AshDispatch.Workers.SendEmail.__info__(:attributes)[:behaviour] || []
      assert Oban.Worker in behaviours
    end

    test "uses :emails queue" do
      # Verify the worker is configured for the correct queue
      assert AshDispatch.Workers.SendEmail.__opts__()[:queue] == :emails
    end
  end

  describe "attachment round-trip (event → transport args → worker)" do
    setup do
      # AshDispatch.Test.Events.OrderCreated ("order.created") implements
      # attachments/2; event discovery needs the test otp_app.
      old_otp_app = Application.get_env(:ash_dispatch, :otp_app)
      Application.put_env(:ash_dispatch, :otp_app, :ash_dispatch_test)

      on_exit(fn ->
        if old_otp_app do
          Application.put_env(:ash_dispatch, :otp_app, old_otp_app)
        else
          Application.delete_env(:ash_dispatch, :otp_app)
        end
      end)

      context = %Context{event_id: "order.created", data: %{}}
      channel = %Channel{transport: :email, audience: :user}

      {:ok, context: context, channel: channel}
    end

    test "transport serializes inline attachments into JSON-safe args", %{
      context: context,
      channel: channel
    } do
      assert [invoice, logo] = Email.resolve_attachments(context, channel)

      # A plain attachment serializes exactly as before inline support: no
      # "type"/"cid" keys at all.
      assert invoice == %{
               "filename" => "faktura.pdf",
               "content_type" => "application/pdf",
               "data" => Base.encode64("%PDF-1.4")
             }

      assert logo == %{
               "filename" => "logo.png",
               "content_type" => "image/png",
               "data" => Base.encode64(<<137, 80, 78, 71>>),
               "type" => "inline",
               "cid" => "logo"
             }
    end

    test "worker decodes what the transport encoded, through JSONB", %{
      context: context,
      channel: channel
    } do
      # Oban stores args as JSONB — encode/decode to prove nothing depends on
      # atoms or binary-unsafe values surviving the trip.
      decoded_args =
        context
        |> Email.resolve_attachments(channel)
        |> Jason.encode!()
        |> Jason.decode!()

      assert [invoice, logo] = SendEmail.decode_attachments(decoded_args)

      assert invoice == %{
               filename: "faktura.pdf",
               content_type: "application/pdf",
               data: "%PDF-1.4",
               type: :attachment,
               cid: nil
             }

      assert logo == %{
               filename: "logo.png",
               content_type: "image/png",
               data: <<137, 80, 78, 71>>,
               type: :inline,
               cid: "logo"
             }
    end

    test "unknown event id yields no attachments", %{channel: channel} do
      context = %Context{event_id: "no.such.event", data: %{}}
      assert Email.resolve_attachments(context, channel) == []
    end
  end

  describe "decode_attachments/1" do
    test "args without type/cid decode as a regular attachment (in-flight jobs)" do
      args = [
        %{
          "filename" => "faktura.pdf",
          "content_type" => "application/pdf",
          "data" => Base.encode64("%PDF-1.4")
        }
      ]

      assert [
               %{
                 filename: "faktura.pdf",
                 content_type: "application/pdf",
                 data: "%PDF-1.4",
                 type: :attachment,
                 cid: nil
               }
             ] = SendEmail.decode_attachments(args)
    end

    test "an inline attachment may omit the cid (backend defaults it to the filename)" do
      args = [
        %{
          "filename" => "logo.png",
          "content_type" => "image/png",
          "data" => Base.encode64("png"),
          "type" => "inline"
        }
      ]

      assert [%{type: :inline, cid: nil}] = SendEmail.decode_attachments(args)
    end

    test "an unrecognized type string falls back to :attachment without creating an atom" do
      args = [
        %{
          "filename" => "x.bin",
          "content_type" => "application/octet-stream",
          "data" => Base.encode64("x"),
          "type" => "ash_dispatch_bogus_attachment_type"
        }
      ]

      assert [%{type: :attachment}] = SendEmail.decode_attachments(args)

      assert_raise ArgumentError, fn ->
        String.to_existing_atom("ash_dispatch_bogus_attachment_type")
      end
    end

    test "drops entries with undecodable data and tolerates missing args" do
      args = [
        %{"filename" => "x.bin", "content_type" => "application/octet-stream", "data" => "!!!"},
        %{"filename" => "no-data.bin"}
      ]

      assert SendEmail.decode_attachments(args) == []
      assert SendEmail.decode_attachments(nil) == []
      assert SendEmail.decode_attachments("not a list") == []
    end
  end
end
