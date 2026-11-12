defmodule AshDispatch.Delivery.DeliveryModeTransportsTest do
  @moduledoc """
  Every transport asks the delivery mode, and nothing reaches a provider when
  the answer is no.

  Until 0.9.3 there was one such setting and it covered email alone: a staging
  host with `skip_email_delivery: true` held back the letters and still sent
  the text messages, posted the webhooks and pushed to the browsers. A source
  guard cannot tell a gate from a gate behind a condition that is never true,
  so each transport is driven through its own send point here.
  """
  # Async disabled: writes :ash_dispatch application config.
  use ExUnit.Case, async: false

  alias AshDispatch.Channel
  alias AshDispatch.Context
  alias AshDispatch.DeliveryMode
  alias AshDispatch.ReceiptStatus
  alias AshDispatch.Test.TransportReceipt
  alias AshDispatch.Transports.InApp
  alias AshDispatch.Transports.Push
  alias AshDispatch.Workers.SendEmail
  alias AshDispatch.Workers.SendSMS
  alias AshDispatch.Workers.SendWebhook

  @moduletag :capture_log

  defmodule EmailBackend do
    @moduledoc false
    def send_email(params) do
      send(self(), {:sent, :email, params})
      {:ok, %{id: "provider-id"}}
    end
  end

  defmodule SkippingEmailBackend do
    @moduledoc false
    def send_email(_params), do: {:skip, "on the provider's suppression list"}
  end

  defmodule SMSBackend do
    @moduledoc false
    @behaviour AshDispatch.SMSBackend

    @impl true
    def deliver(receipt, _context, _channel, _event_config) do
      send(self(), {:sent, :sms, receipt.recipient})
      {:ok, ReceiptStatus.mark_sent(receipt, %{"id" => "s1"})}
    end
  end

  defmodule PushBackend do
    @moduledoc false
    @behaviour AshDispatch.PushBackend

    @impl true
    def deliver(receipt, _context, _channel, _event_config) do
      send(self(), {:sent, :push, receipt.recipient})
      {:ok, ReceiptStatus.mark_sent(receipt, %{})}
    end
  end

  @keys [
    :otp_app,
    :delivery_receipt_resource,
    :email_backend,
    :sms_backend,
    :push_backend,
    :delivery_mode,
    :skip_email_delivery
  ]

  setup do
    saved = for key <- @keys, do: {key, Application.get_env(:ash_dispatch, key)}

    on_exit(fn ->
      for {key, value} <- saved do
        if is_nil(value),
          do: Application.delete_env(:ash_dispatch, key),
          else: Application.put_env(:ash_dispatch, key, value)
      end

      # The receipts this file writes are not another file's business, and
      # `stop/1` waits for the table's owner to be gone (the 0.9.1 fix).
      AshDispatch.Test.Ets.stop(TransportReceipt)
    end)

    for key <- @keys, do: Application.delete_env(:ash_dispatch, key)

    Application.put_env(:ash_dispatch, :otp_app, :ash_dispatch_test)
    Application.put_env(:ash_dispatch, :delivery_receipt_resource, TransportReceipt)
    Application.put_env(:ash_dispatch, :email_backend, EmailBackend)
    Application.put_env(:ash_dispatch, :sms_backend, SMSBackend)
    Application.put_env(:ash_dispatch, :push_backend, PushBackend)

    :ok
  end

  defp put_mode(mode), do: Application.put_env(:ash_dispatch, :delivery_mode, mode)

  defp receipt!(transport, attrs \\ %{}) do
    TransportReceipt
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          status: :scheduled,
          event_id: "ticket.created",
          audience: :user,
          transport: transport,
          user_id: "11111111-1111-1111-1111-111111111111",
          recipient: default_recipient(transport),
          subject: "Your ticket",
          body_text: "Your ticket was created",
          body_html: "<p>Your ticket was created</p>",
          content: %{title: "Your ticket", message: "Your ticket was created"}
        },
        attrs
      )
    )
    |> Ash.create!(authorize?: false)
  end

  defp default_recipient(:sms), do: "+46701234567"
  defp default_recipient(_transport), do: "customer@example.com"

  defp reload(receipt), do: Ash.get!(TransportReceipt, receipt.id, authorize?: false)

  # The send point of each transport, driven exactly as production drives it.
  # `:in_app` and `:push` deliver synchronously from the transport; the other
  # three from their Oban worker.
  defp send_now(%{transport: :email} = receipt),
    do: SendEmail.perform(%Oban.Job{args: %{"receipt_id" => receipt.id}})

  defp send_now(%{transport: :sms} = receipt),
    do: SendSMS.perform(%Oban.Job{args: %{"receipt_id" => receipt.id}})

  # `:slack` and `:discord` travel the same worker as `:webhook`, and their
  # receipts carry their own transport — so they read their own mode.
  defp send_now(%{transport: transport} = receipt)
       when transport in [:webhook, :slack, :discord] do
    SendWebhook.perform(%Oban.Job{
      args: %{"receipt_id" => receipt.id, "webhook_url" => "https://example.test/hook"}
    })
  end

  defp send_now(%{transport: :in_app} = receipt) do
    InApp.deliver(receipt, context(), %Channel{transport: :in_app, audience: :user}, %{})
  end

  defp send_now(%{transport: :push} = receipt) do
    Push.deliver(receipt, context(), %Channel{transport: :push, audience: :user}, %{})
  end

  defp context, do: %Context{event_id: "ticket.created", data: %{}}

  @transports [:email, :sms, :webhook, :in_app, :push, :slack, :discord]

  describe ":blocked" do
    test "every transport holds back, and no provider is reached" do
      put_mode(:blocked)

      for transport <- @transports do
        receipt = receipt!(transport)
        send_now(receipt)

        held = reload(receipt)
        assert held.status == :skipped, "#{transport} was not held back"
        assert held.error_message == DeliveryMode.reason(:blocked), "#{transport}"
      end

      refute_received {:sent, _transport, _params}
    end
  end

  describe ":dry_run" do
    test "every transport goes through the whole path and sends nothing" do
      put_mode(:dry_run)

      for transport <- @transports do
        receipt = receipt!(transport)
        send_now(receipt)

        held = reload(receipt)
        assert held.status == :skipped, "#{transport} was not held back"
        assert held.error_message == DeliveryMode.reason(:dry_run), "#{transport}"

        # What would have been sent is on the receipt, which is the record a
        # dry run exists to leave behind.
        assert held.recipient == default_recipient(transport)
        assert held.body_text == "Your ticket was created"
      end

      refute_received {:sent, _transport, _params}
    end
  end

  describe ":live" do
    test "email reaches the backend and the receipt is sent" do
      put_mode(:live)
      receipt = receipt!(:email)

      assert :ok = send_now(receipt)
      assert_received {:sent, :email, %{to: "customer@example.com"}}
      assert reload(receipt).status == :sent
    end

    test "sms reaches the backend and the receipt is sent" do
      put_mode(:live)
      receipt = receipt!(:sms)

      assert :ok = send_now(receipt)
      assert_received {:sent, :sms, "+46701234567"}
      assert reload(receipt).status == :sent
    end

    test "push reaches the backend and the receipt is sent" do
      put_mode(:live)
      receipt = receipt!(:push)

      assert {:ok, _} = send_now(receipt)
      assert_received {:sent, :push, "customer@example.com"}
      assert reload(receipt).status == :sent
    end

    # The library suite has no notification resource, so an in-app delivery
    # cannot complete here. What matters is the reason: the mode did not stop
    # it. (Same reasoning as the preference-gating tests.)
    test "in_app is not held back" do
      put_mode(:live)
      receipt = receipt!(:in_app)

      send_now(receipt)

      refute reload(receipt).error_message in [
               DeliveryMode.reason(:blocked),
               DeliveryMode.reason(:dry_run),
               DeliveryMode.reason(:not_allowed)
             ]
    end

    test "a host that sets nothing at all behaves the same as :live" do
      Application.delete_env(:ash_dispatch, :delivery_mode)
      receipt = receipt!(:email)

      assert :ok = send_now(receipt)
      assert_received {:sent, :email, _params}
    end
  end

  describe "an allow-list" do
    test "sends to an address on the list and holds back the rest" do
      put_mode({:allow_list, ["ops@example.com", "@example.test"]})

      allowed = receipt!(:email, %{recipient: "ops@example.com"})
      assert :ok = send_now(allowed)
      assert_received {:sent, :email, %{to: "ops@example.com"}}
      assert reload(allowed).status == :sent

      by_domain = receipt!(:email, %{recipient: "anyone@example.test"})
      assert :ok = send_now(by_domain)
      assert_received {:sent, :email, %{to: "anyone@example.test"}}

      blocked = receipt!(:email, %{recipient: "customer@example.com"})
      assert :ok = send_now(blocked)
      refute_received {:sent, :email, _params}
      assert reload(blocked).error_message == DeliveryMode.reason(:not_allowed)
    end

    test "matches a phone prefix on the sms transport" do
      put_mode({:allow_list, ["+4670"]})

      allowed = receipt!(:sms, %{recipient: "+46701234567"})
      assert :ok = send_now(allowed)
      assert_received {:sent, :sms, _number}

      blocked = receipt!(:sms, %{recipient: "+46731234567"})
      assert :ok = send_now(blocked)
      refute_received {:sent, :sms, _number}
      assert reload(blocked).error_message == DeliveryMode.reason(:not_allowed)
    end
  end

  describe "skip_email_delivery, as before" do
    test "email is skipped with the reason it has always written" do
      Application.put_env(:ash_dispatch, :skip_email_delivery, true)
      receipt = receipt!(:email)

      assert :ok = send_now(receipt)
      refute_received {:sent, :email, _params}

      held = reload(receipt)
      assert held.status == :skipped
      assert held.error_message == "email delivery disabled (dev mode)"
    end

    test "and the other transports still send — the gap this release closes" do
      Application.put_env(:ash_dispatch, :skip_email_delivery, true)

      sms = receipt!(:sms)
      assert :ok = send_now(sms)
      assert_received {:sent, :sms, _number}

      push = receipt!(:push)
      assert {:ok, _} = send_now(push)
      assert_received {:sent, :push, _recipient}
    end
  end

  describe "a backend that answers skipped" do
    test "the receipt is skipped, not failed and not sent" do
      Application.put_env(:ash_dispatch, :email_backend, SkippingEmailBackend)
      receipt = receipt!(:email)

      assert :ok = send_now(receipt)

      skipped = reload(receipt)
      assert skipped.status == :skipped
      assert skipped.error_message == "on the provider's suppression list"
    end
  end

  describe "structural: every send point asks" do
    # The list is globbed rather than maintained: a transport or worker added
    # tomorrow is covered without anyone remembering to add it here.
    @send_points Path.wildcard("lib/workers/send_*.ex") ++
                   ["lib/transports/in_app.ex", "lib/transports/push.ex"]

    test "the glob found the send points" do
      assert length(@send_points) >= 5, "expected the send workers, got #{inspect(@send_points)}"
    end

    test "each one reads the delivery mode through AshDispatch.Delivery" do
      missing =
        Enum.reject(@send_points, fn path ->
          source = File.read!(path)
          source =~ "Delivery.verdict(receipt)" or source =~ "Delivery.mode_verdict(receipt)"
        end)

      assert missing == [], """
      These send points do not ask whether the delivery may go out:

        #{inspect(missing)}

      Call `AshDispatch.Delivery.verdict(receipt)` (a worker) or
      `AshDispatch.Delivery.mode_verdict(receipt)` (a transport that delivers
      synchronously) before anything reaches a provider.
      """
    end

    # The setting it replaces must have exactly one reader left, so the mapping
    # cannot drift: two readers is how `skip_email_delivery` came to mean one
    # thing in the worker and nothing anywhere else.
    test "skip_email_delivery is read in one place only" do
      readers =
        Path.wildcard("lib/**/*.ex")
        |> Enum.filter(&(File.read!(&1) =~ "Config.skip_email_delivery?()"))

      assert readers == ["lib/delivery_mode.ex"], inspect(readers)
    end
  end
end
