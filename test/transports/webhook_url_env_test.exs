defmodule AshDispatch.Transports.WebhookUrlEnvTest do
  @moduledoc """
  A Slack or Discord webhook URL is a credential: whoever has it can post to
  the channel. These tests hold three things:

    1. With `metadata.webhook_url_env` the job args — what lands in
       `oban_jobs.args` and stays there — carry the variable's NAME and never
       the URL, and the worker reads the URL when it sends.
    2. No log line from `AshDispatch.Workers.SendWebhook` carries the URL, at
       any level, on 2xx, 4xx, 5xx or a timeout.
    3. A channel with neither `webhook_url_env` nor a URL is skipped exactly as
       before: `:skipped`, "No webhook_url configured".
  """

  # Async disabled: sets environment variables, the worker's Req options and
  # per-module log levels, all of which are global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :capture_log

  alias AshDispatch.Channel
  alias AshDispatch.Context
  alias AshDispatch.Test.TransportReceipt
  alias AshDispatch.Transports.Discord
  alias AshDispatch.Transports.Slack
  alias AshDispatch.Transports.WebhookUrl
  alias AshDispatch.Workers.SendWebhook

  @env "ASH_DISPATCH_TEST_SLACK_WEBHOOK_URL"
  # The part of a Slack webhook URL that is the credential.
  @secret_path "T000/B000/s3cr3tXoXo"
  @url "https://hooks.slack.test/services/" <> @secret_path

  setup do
    System.put_env(@env, @url)
    previous = Application.get_env(:ash_dispatch, SendWebhook)

    Application.put_env(:ash_dispatch, SendWebhook, req_options: [plug: {Req.Test, __MODULE__}])

    Logger.put_module_level(SendWebhook, :debug)

    on_exit(fn ->
      System.delete_env(@env)
      Logger.delete_module_level(SendWebhook)

      if previous,
        do: Application.put_env(:ash_dispatch, SendWebhook, previous),
        else: Application.delete_env(:ash_dispatch, SendWebhook)
    end)

    :ok
  end

  defp receipt do
    %{id: Ecto.UUID.generate(), content: %{notification_message: "Order 1 created"}}
  end

  defp env_channel(transport),
    do: %Channel{transport: transport, audience: :team, metadata: %{webhook_url_env: @env}}

  # What Oban stores: the args after a JSON round trip.
  defp stored(args), do: args |> Jason.encode!() |> Jason.decode!()

  describe "1. the URL is not in the job args" do
    for {transport, modul} <- [slack: Slack, discord: Discord] do
      test "#{transport}: webhook_url_env puts the name in the args and no URL" do
        assert {:ok, args} =
                 unquote(modul).job_args(receipt(), %Context{}, env_channel(unquote(transport)))

        args = stored(args)

        assert args["webhook_url_env"] == @env
        refute Map.has_key?(args, "webhook_url")
        refute Jason.encode!(args) =~ @secret_path
        refute Jason.encode!(args) =~ "hooks.slack.test"
      end
    end

    test "string-keyed metadata works the same way" do
      channel = %Channel{
        transport: :slack,
        audience: :team,
        metadata: %{"webhook_url_env" => @env}
      }

      assert {:ok, args} = Slack.job_args(receipt(), %Context{}, channel)
      assert stored(args)["webhook_url_env"] == @env
      refute Jason.encode!(args) =~ @secret_path
    end

    test "an explicit webhook_url still travels as before" do
      channel = %Channel{transport: :slack, audience: :team, webhook_url: "https://x.test/h"}

      assert {:ok, %{"webhook_url" => "https://x.test/h"} = args} =
               Slack.job_args(receipt(), %Context{}, channel)

      refute Map.has_key?(args, "webhook_url_env")
    end

    test "the worker reads the URL from the environment when it sends" do
      {:ok, args} = Slack.job_args(receipt(), %Context{}, env_channel(:slack))
      # Rotated after enqueue: the job must post to the NEW value.
      rotated = "https://hooks.slack.test/services/T000/B000/rotated"
      System.put_env(@env, rotated)

      Req.Test.stub(__MODULE__, fn conn ->
        send(self(), {:posted, conn.host, conn.request_path})
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert {:ok, %{status: 200}} = SendWebhook.request(stored(args))
      assert_received {:posted, "hooks.slack.test", "/services/T000/B000/rotated"}
    end

    test "an unset variable at send time is an error that names it, not a URL" do
      {:ok, args} = Slack.job_args(receipt(), %Context{}, env_channel(:slack))
      System.delete_env(@env)

      log =
        capture_log([level: :debug], fn ->
          assert {:error, reason} = SendWebhook.request(stored(args))
          assert reason =~ @env
        end)

      assert log =~ @env
    end
  end

  describe "2. no log line carries the URL" do
    defp logged(response) do
      Req.Test.stub(__MODULE__, response)

      capture_log([level: :debug], fn ->
        SendWebhook.request(%{"receipt_id" => "r1", "webhook_url_env" => @env, "payload" => %{}})
      end)
    end

    test "2xx" do
      log = logged(&Req.Test.json(&1, %{"ok" => true}))
      assert log =~ "status=200"
      assert log =~ "hooks.slack.test"
      refute log =~ @secret_path
    end

    test "the debug line" do
      log = logged(&Req.Test.json(&1, %{"ok" => true}))
      assert log =~ "Sending webhook"
      refute log =~ @secret_path
    end

    test "4xx, even when the body echoes the URL" do
      log =
        logged(fn conn ->
          conn
          |> Plug.Conn.put_status(404)
          |> Req.Test.json(%{"error" => "no_service", "url" => @url})
        end)

      assert log =~ "status=404"
      refute log =~ @secret_path
    end

    test "5xx" do
      log = logged(&(&1 |> Plug.Conn.put_status(503) |> Req.Test.json(%{})))
      assert log =~ "status=503"
      refute log =~ @secret_path
    end

    test "a timeout" do
      log = logged(&Req.Test.transport_error(&1, :timeout))
      assert log =~ "timeout"
      refute log =~ @secret_path
    end

    test "an explicit URL in the args is masked too" do
      Req.Test.stub(__MODULE__, &(&1 |> Plug.Conn.put_status(500) |> Req.Test.json(%{})))

      log =
        capture_log([level: :debug], fn ->
          SendWebhook.request(%{"receipt_id" => "r1", "webhook_url" => @url, "payload" => %{}})
        end)

      assert log =~ "status=500"
      refute log =~ @secret_path
    end
  end

  describe "WebhookUrl.mask/1 and scrub/2" do
    test "keep scheme and host only" do
      assert WebhookUrl.mask(@url) == "https://hooks.slack.test/[redacted]"
      assert WebhookUrl.mask("https://u:p@x.test/?token=t") == "https://x.test/[redacted]"
      assert WebhookUrl.mask("not a url") == "[redacted]"
      assert WebhookUrl.mask(nil) == "[redacted]"
    end

    test "scrub replaces every occurrence" do
      assert WebhookUrl.scrub("a #{@url} b #{@url}", @url) ==
               "a https://hooks.slack.test/[redacted] b https://hooks.slack.test/[redacted]"

      assert WebhookUrl.scrub("x", nil) == "x"
    end
  end

  describe "3. skipping is unchanged" do
    defp receipt!(transport) do
      TransportReceipt
      |> Ash.Changeset.for_create(:create, %{
        event_id: "orders.created",
        audience: :team,
        transport: transport,
        recipient: "team",
        subject: "Order",
        body_html: "<p>Order</p>",
        body_text: "Order",
        content: %{notification_message: "Order"}
      })
      |> Ash.create!(authorize?: false)
    end

    for {transport, modul} <- [slack: Slack, discord: Discord] do
      test "#{transport}: neither webhook_url_env nor a URL is :skipped as before" do
        channel = %Channel{transport: unquote(transport), audience: :team}

        assert {:ok, skipped} =
                 unquote(modul).deliver(receipt!(unquote(transport)), %Context{}, channel, [])

        assert skipped.status == :skipped
        assert skipped.error_message == "No webhook_url configured"
      end

      test "#{transport}: webhook_url_env naming an unset variable is :skipped and says which" do
        System.delete_env(@env)

        assert {:ok, skipped} =
                 unquote(modul).deliver(
                   receipt!(unquote(transport)),
                   %Context{},
                   env_channel(unquote(transport)),
                   []
                 )

        assert skipped.status == :skipped
        assert skipped.error_message == "webhook_url_env #{@env} is not set"
      end
    end
  end
end
