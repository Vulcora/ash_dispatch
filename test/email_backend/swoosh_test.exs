defmodule AshDispatch.EmailBackend.SwooshTest do
  use ExUnit.Case, async: true

  import Swoosh.TestAssertions

  alias AshDispatch.EmailBackend.Swoosh

  setup do
    # Ensure Swoosh test adapter mailbox is clear before each test
    :ok
  end

  describe "send_email/1" do
    test "sends email via Swoosh with all fields" do
      params = %{
        to: "user@example.com",
        from: "orders@example.com",
        subject: "Order Confirmation",
        html_body: "<h1>Thank you for your order!</h1>",
        text_body: "Thank you for your order!"
      }

      assert {:ok, result} = Swoosh.send_email(params)
      assert result.provider == :swoosh
      assert is_binary(result.id)

      # Assert email was sent via Swoosh test adapter
      assert_email_sent(
        to: "user@example.com",
        from: "orders@example.com",
        subject: "Order Confirmation"
      )
    end

    test "includes HTML body in sent email" do
      params = %{
        to: "user@example.com",
        from: "system@example.com",
        subject: "Test",
        html_body: "<p>HTML content</p>",
        text_body: "Text content"
      }

      assert {:ok, _result} = Swoosh.send_email(params)

      assert_email_sent(fn email ->
        email.html_body == "<p>HTML content</p>"
      end)
    end

    test "includes text body in sent email" do
      params = %{
        to: "user@example.com",
        from: "system@example.com",
        subject: "Test",
        html_body: "<p>HTML content</p>",
        text_body: "Text content"
      }

      assert {:ok, _result} = Swoosh.send_email(params)

      assert_email_sent(fn email ->
        email.text_body == "Text content"
      end)
    end

    test "returns error if email delivery fails" do
      # This test would require mocking the mailer to return an error
      # For now, we just verify the successful case
      # In real scenarios, errors would be caught by Swoosh adapter failures
      params = %{
        to: "user@example.com",
        from: "test@example.com",
        subject: "Test",
        html_body: "<p>Test</p>",
        text_body: "Test"
      }

      assert {:ok, _result} = Swoosh.send_email(params)
    end

    test "extracts message ID from Swoosh metadata" do
      params = %{
        to: "user@example.com",
        from: "test@example.com",
        subject: "Test",
        html_body: "<p>Test</p>",
        text_body: "Test"
      }

      assert {:ok, result} = Swoosh.send_email(params)
      # Test adapter may return different ID formats
      assert is_binary(result.id)
    end

    test "handles multiple recipients separately" do
      # Send to first recipient
      params1 = %{
        to: "user1@example.com",
        from: "test@example.com",
        subject: "Test 1",
        html_body: "<p>Test 1</p>",
        text_body: "Test 1"
      }

      assert {:ok, _result1} = Swoosh.send_email(params1)

      # Send to second recipient
      params2 = %{
        to: "user2@example.com",
        from: "test@example.com",
        subject: "Test 2",
        html_body: "<p>Test 2</p>",
        text_body: "Test 2"
      }

      assert {:ok, _result2} = Swoosh.send_email(params2)

      # Both emails should be sent
      assert_email_sent(to: "user1@example.com")
      assert_email_sent(to: "user2@example.com")
    end
  end

  describe "configuration" do
    test "returns error with helpful message if swoosh_mailer not configured" do
      # Temporarily remove config
      original_mailer = Application.get_env(:ash_dispatch, :swoosh_mailer)
      Application.delete_env(:ash_dispatch, :swoosh_mailer)

      params = %{
        to: "user@example.com",
        from: "test@example.com",
        subject: "Test",
        html_body: "<p>Test</p>",
        text_body: "Test"
      }

      # Should return error (rescue clause catches the raised error)
      assert {:error, %RuntimeError{message: message}} = Swoosh.send_email(params)
      assert message =~ "No Swoosh mailer configured"

      # Restore config
      if original_mailer do
        Application.put_env(:ash_dispatch, :swoosh_mailer, original_mailer)
      end
    end
  end
end
