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

    test "attachment map without :type/:cid stays a plain attachment (legacy shape)" do
      # Args enqueued before inline support decode to exactly this map — it
      # must keep producing the pre-inline `%Swoosh.Attachment{}`.
      capture_log(fn ->
        assert {:ok, %{provider: :swoosh}} =
                 SwooshBackend.send_email(%{
                   to: "user@example.com",
                   from: "noreply@example.com",
                   subject: "With invoice",
                   html_body: "<p>Invoice</p>",
                   text_body: "Invoice",
                   attachments: [
                     %{
                       filename: "faktura.pdf",
                       content_type: "application/pdf",
                       data: "%PDF-1.4"
                     }
                   ]
                 })
      end)

      assert_email_sent(fn email ->
        assert [attachment] = email.attachments
        assert attachment.filename == "faktura.pdf"
        assert attachment.type == :attachment
        assert attachment.cid == nil
      end)
    end

    test "embeds inline images with a cid derived from the filename" do
      capture_log(fn ->
        assert {:ok, %{provider: :swoosh}} =
                 SwooshBackend.send_email(%{
                   to: "user@example.com",
                   from: "noreply@example.com",
                   subject: "With logo",
                   html_body: ~s(<img src="cid:logo.png" alt="Logo" />),
                   text_body: "Logo",
                   attachments: [
                     %{
                       filename: "logo.png",
                       content_type: "image/png",
                       data: <<137, 80, 78, 71>>,
                       type: :inline,
                       cid: nil
                     }
                   ]
                 })
      end)

      assert_email_sent(fn email ->
        assert [attachment] = email.attachments

        assert %Swoosh.Attachment{
                 filename: "logo.png",
                 content_type: "image/png",
                 type: :inline,
                 cid: "logo.png",
                 data: <<137, 80, 78, 71>>
               } = attachment
      end)
    end

    test "honours an explicit :cid for inline attachments" do
      capture_log(fn ->
        assert {:ok, %{provider: :swoosh}} =
                 SwooshBackend.send_email(%{
                   to: "user@example.com",
                   from: "noreply@example.com",
                   subject: "With logo",
                   html_body: ~s(<img src="cid:logo" alt="Logo" />),
                   text_body: "Logo",
                   attachments: [
                     %{
                       filename: "logo.png",
                       content_type: "image/png",
                       data: <<137, 80, 78, 71>>,
                       type: :inline,
                       cid: "logo"
                     }
                   ]
                 })
      end)

      assert_email_sent(fn email ->
        assert [%Swoosh.Attachment{type: :inline, cid: "logo"}] = email.attachments
      end)
    end

    test "ignores a :cid on a regular attachment" do
      capture_log(fn ->
        assert {:ok, %{provider: :swoosh}} =
                 SwooshBackend.send_email(%{
                   to: "user@example.com",
                   from: "noreply@example.com",
                   subject: "With invoice",
                   html_body: "<p>Invoice</p>",
                   text_body: "Invoice",
                   attachments: [
                     %{
                       filename: "faktura.pdf",
                       content_type: "application/pdf",
                       data: "%PDF-1.4",
                       type: :attachment,
                       cid: "invoice"
                     }
                   ]
                 })
      end)

      assert_email_sent(fn email ->
        assert [%Swoosh.Attachment{type: :attachment, cid: nil}] = email.attachments
      end)
    end

    test "mixes inline and regular attachments in one email" do
      capture_log(fn ->
        assert {:ok, %{provider: :swoosh}} =
                 SwooshBackend.send_email(%{
                   to: "user@example.com",
                   from: "noreply@example.com",
                   subject: "Order confirmation",
                   html_body: ~s(<img src="cid:logo.png" /><p>Thanks!</p>),
                   text_body: "Thanks!",
                   attachments: [
                     %{
                       filename: "logo.png",
                       content_type: "image/png",
                       data: <<137, 80, 78, 71>>,
                       type: :inline,
                       cid: nil
                     },
                     %{
                       filename: "faktura.pdf",
                       content_type: "application/pdf",
                       data: "%PDF-1.4",
                       type: :attachment,
                       cid: nil
                     }
                   ]
                 })
      end)

      assert_email_sent(fn email ->
        # Swoosh prepends, so the list comes back in reverse order.
        assert [%Swoosh.Attachment{filename: "faktura.pdf", type: :attachment, cid: nil}, inline] =
                 email.attachments

        assert %Swoosh.Attachment{filename: "logo.png", type: :inline, cid: "logo.png"} = inline
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
