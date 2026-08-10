defmodule AshDispatch.EmailBackend.SwooshTest do
  @moduledoc """
  Tests for the Swoosh email backend.

  These tests verify that the backend correctly handles various email address formats
  including tuples (Swoosh's named address format) and strings.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Swoosh.TestAssertions

  alias AshDispatch.EmailBackend.Swoosh, as: SwooshBackend

  setup do
    # Configure test mailer for these tests
    Application.put_env(:ash_dispatch, :swoosh_mailer, AshDispatch.Test.Mailer)

    on_exit(fn ->
      Application.delete_env(:ash_dispatch, :swoosh_mailer)
    end)

    :ok
  end

  describe "send_email/1" do
    test "sends email with string from address" do
      capture_log(fn ->
        result =
          SwooshBackend.send_email(%{
            to: "user@example.com",
            from: "noreply@example.com",
            subject: "Test Subject",
            html_body: "<p>Test HTML</p>",
            text_body: "Test Text"
          })

        assert {:ok, %{provider: :swoosh}} = result
      end)

      assert_email_sent(to: "user@example.com", subject: "Test Subject")
    end

    test "sends email with tuple from address (named sender)" do
      capture_log(fn ->
        result =
          SwooshBackend.send_email(%{
            to: "user@example.com",
            from: {"System", "noreply@example.com"},
            subject: "Test Subject",
            html_body: "<p>Test HTML</p>",
            text_body: "Test Text"
          })

        assert {:ok, %{provider: :swoosh}} = result
      end)

      assert_email_sent(to: "user@example.com", subject: "Test Subject")
    end

    test "sends email with tuple to address (named recipient)" do
      capture_log(fn ->
        result =
          SwooshBackend.send_email(%{
            to: {"User Name", "user@example.com"},
            from: "noreply@example.com",
            subject: "Test Subject",
            html_body: "<p>Test HTML</p>",
            text_body: "Test Text"
          })

        assert {:ok, %{provider: :swoosh}} = result
      end)

      assert_email_sent(subject: "Test Subject")
    end

    test "sends email with both tuple from and to addresses" do
      capture_log(fn ->
        result =
          SwooshBackend.send_email(%{
            to: {"Recipient", "user@example.com"},
            from: {"Sender", "noreply@example.com"},
            subject: "Test Subject",
            html_body: "<p>Test HTML</p>",
            text_body: "Test Text"
          })

        assert {:ok, %{provider: :swoosh}} = result
      end)

      assert_email_sent(subject: "Test Subject")
    end

    test "attaches files when :attachments provided" do
      capture_log(fn ->
        result =
          SwooshBackend.send_email(%{
            to: "user@example.com",
            from: "noreply@example.com",
            subject: "With calendar",
            html_body: "<p>Invite</p>",
            text_body: "Invite",
            attachments: [
              %{
                filename: "mote.ics",
                content_type: "text/calendar",
                data: "BEGIN:VCALENDAR\nEND:VCALENDAR"
              }
            ]
          })

        assert {:ok, %{provider: :swoosh}} = result
      end)

      assert_email_sent(fn email ->
        assert [%Swoosh.Attachment{filename: "mote.ics", content_type: "text/calendar"}] =
                 email.attachments
      end)
    end

    test "sends without attachments when :attachments omitted (backward compatible)" do
      capture_log(fn ->
        assert {:ok, %{provider: :swoosh}} =
                 SwooshBackend.send_email(%{
                   to: "user@example.com",
                   from: "noreply@example.com",
                   subject: "No attach",
                   html_body: "<p>Hi</p>",
                   text_body: "Hi"
                 })
      end)

      assert_email_sent(fn email -> assert email.attachments == [] end)
    end

    test "handles Swedish characters in sender name" do
      capture_log(fn ->
        result =
          SwooshBackend.send_email(%{
            to: "user@example.com",
            from: {"Fyndgrossisten Ärenden", "arenden@fyndgrossisten.se"},
            subject: "Välkommen!",
            html_body: "<p>Hälsningar</p>",
            text_body: "Hälsningar"
          })

        assert {:ok, %{provider: :swoosh}} = result
      end)

      assert_email_sent(subject: "Välkommen!")
    end
  end

  describe "error handling" do
    test "returns error when mailer is not configured" do
      # Temporarily remove the mailer config
      original = Application.get_env(:ash_dispatch, :swoosh_mailer)
      Application.put_env(:ash_dispatch, :swoosh_mailer, nil)

      try do
        capture_log(fn ->
          # The function catches the RuntimeError and returns {:error, error}
          result =
            SwooshBackend.send_email(%{
              to: "user@example.com",
              from: "noreply@example.com",
              subject: "Test",
              html_body: "<p>Test</p>",
              text_body: "Test"
            })

          assert {:error, %RuntimeError{message: message}} = result
          assert message =~ "No Swoosh mailer configured"
        end)
      after
        # Restore original config
        if original do
          Application.put_env(:ash_dispatch, :swoosh_mailer, original)
        end
      end
    end
  end
end
