defmodule AshDispatch.WebhookHandlers.ResendTest do
  @moduledoc """
  Tests for the Resend webhook handler.

  Verifies that webhooks correctly look up delivery receipts by provider_id
  and update them with event data.
  """
  use ExUnit.Case, async: false

  # Capture logs to suppress Ash ETS data layer debug noise
  # (Ash has a bug formatting DateTime in debug logs - see deps/ash/.../ets.ex:2308)
  @moduletag :capture_log

  alias AshDispatch.WebhookHandlers.Resend
  alias AshDispatch.Test.DeliveryReceipt

  setup do
    # Configure test delivery receipt resource
    Application.put_env(:ash_dispatch, :delivery_receipt_resource, DeliveryReceipt)

    on_exit(fn ->
      Application.delete_env(:ash_dispatch, :delivery_receipt_resource)
    end)

    :ok
  end

  describe "process_webhook/1" do
    test "finds receipt by provider_id and updates it" do
      # Create a receipt with a known provider_id
      provider_id = "resend_#{System.unique_integer([:positive])}"

      {:ok, receipt} =
        DeliveryReceipt
        |> Ash.Changeset.for_create(:create, %{
          provider_id: provider_id,
          status: :sent,
          recipient: "test@example.com",
          transport: :email
        })
        |> Ash.create()

      # Simulate Resend webhook for email.delivered
      webhook_params = %{
        "type" => "email.delivered",
        "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "data" => %{
          "email_id" => provider_id,
          "to" => ["test@example.com"]
        }
      }

      assert {:ok, updated_receipt} = Resend.process_webhook(webhook_params)
      assert updated_receipt.id == receipt.id
      assert updated_receipt.delivered_at != nil
    end

    test "returns not_found when provider_id doesn't match any receipt" do
      webhook_params = %{
        "type" => "email.delivered",
        "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "data" => %{
          "email_id" => "nonexistent_id_#{System.unique_integer([:positive])}"
        }
      }

      assert {:error, :not_found} = Resend.process_webhook(webhook_params)
    end

    test "returns missing_email_id when webhook has no email_id" do
      webhook_params = %{
        "type" => "email.delivered",
        "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "data" => %{}
      }

      assert {:error, :missing_email_id} = Resend.process_webhook(webhook_params)
    end

    test "returns invalid_format for malformed webhook" do
      assert {:error, :invalid_format} = Resend.process_webhook(%{"invalid" => "data"})
    end

    test "updates opened_at for email.opened event" do
      provider_id = "resend_#{System.unique_integer([:positive])}"

      {:ok, _receipt} =
        DeliveryReceipt
        |> Ash.Changeset.for_create(:create, %{
          provider_id: provider_id,
          status: :sent,
          recipient: "test@example.com"
        })
        |> Ash.create()

      webhook_params = %{
        "type" => "email.opened",
        "created_at" => "2024-01-15T10:30:00Z",
        "data" => %{"email_id" => provider_id}
      }

      assert {:ok, updated} = Resend.process_webhook(webhook_params)
      assert updated.opened_at != nil
    end

    test "updates clicked_at for email.clicked event" do
      provider_id = "resend_#{System.unique_integer([:positive])}"

      {:ok, _receipt} =
        DeliveryReceipt
        |> Ash.Changeset.for_create(:create, %{
          provider_id: provider_id,
          status: :sent,
          recipient: "test@example.com"
        })
        |> Ash.create()

      webhook_params = %{
        "type" => "email.clicked",
        "created_at" => "2024-01-15T10:35:00Z",
        "data" => %{"email_id" => provider_id}
      }

      assert {:ok, updated} = Resend.process_webhook(webhook_params)
      assert updated.clicked_at != nil
    end

    test "updates bounced_at for email.bounced event" do
      provider_id = "resend_#{System.unique_integer([:positive])}"

      {:ok, _receipt} =
        DeliveryReceipt
        |> Ash.Changeset.for_create(:create, %{
          provider_id: provider_id,
          status: :sent,
          recipient: "test@example.com"
        })
        |> Ash.create()

      webhook_params = %{
        "type" => "email.bounced",
        "created_at" => "2024-01-15T10:40:00Z",
        "data" => %{"email_id" => provider_id, "bounce_type" => "hard"}
      }

      assert {:ok, updated} = Resend.process_webhook(webhook_params)
      assert updated.bounced_at != nil
    end

    test "updates failed_at for email.failed event" do
      provider_id = "resend_#{System.unique_integer([:positive])}"

      {:ok, _receipt} =
        DeliveryReceipt
        |> Ash.Changeset.for_create(:create, %{
          provider_id: provider_id,
          status: :sent,
          recipient: "test@example.com"
        })
        |> Ash.create()

      webhook_params = %{
        "type" => "email.failed",
        "created_at" => "2024-01-15T10:45:00Z",
        "data" => %{"email_id" => provider_id, "reason" => "Invalid recipient"}
      }

      assert {:ok, updated} = Resend.process_webhook(webhook_params)
      assert updated.failed_at != nil
    end
  end

  describe "verify/4" do
    @secret_key :crypto.strong_rand_bytes(24)
    @secret "whsec_" <> Base.encode64(@secret_key)

    defp sign(body, id, ts, key \\ @secret_key) do
      "v1," <> Base.encode64(:crypto.mac(:hmac, :sha256, key, "#{id}.#{ts}.#{body}"))
    end

    defp headers(body, opts \\ []) do
      id = Keyword.get(opts, :id, "msg_1")
      ts = Keyword.get(opts, :ts, to_string(Keyword.get(opts, :now, 1_700_000_000)))

      %{
        "svix-id" => id,
        "svix-timestamp" => ts,
        "svix-signature" => Keyword.get(opts, :sig, sign(body, id, ts))
      }
    end

    test "valid signature passes" do
      body = ~s({"type":"email.opened"})
      assert :ok = Resend.verify(body, headers(body), @secret, now: 1_700_000_000)
    end

    test "rotated secrets: any matching signature in the list passes" do
      body = "x"
      good = sign(body, "msg_1", "1700000000")
      hdrs = %{headers(body) | "svix-signature" => "v1,AAAA #{good}"}
      assert :ok = Resend.verify(body, hdrs, @secret, now: 1_700_000_000)
    end

    test "tampered body is rejected" do
      hdrs = headers("original")

      assert {:error, :signature_mismatch} =
               Resend.verify("tampered", hdrs, @secret, now: 1_700_000_000)
    end

    test "stale timestamp is rejected" do
      body = "x"

      assert {:error, :stale_timestamp} =
               Resend.verify(body, headers(body), @secret, now: 1_700_000_000 + 3600)
    end

    test "missing headers and bad secret are rejected" do
      assert {:error, :missing_headers} = Resend.verify("x", %{}, @secret)
      body = "x"

      assert {:error, :invalid_secret} =
               Resend.verify(body, headers(body), "whsec_!!!", now: 1_700_000_000)
    end
  end
end
