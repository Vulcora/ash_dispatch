defmodule AshDispatch.Transports.RenderedBodyReachesPayloadTest do
  @moduledoc """
  A rendered `slack.text.eex` or `discord.text.eex` reaches the payload that
  is actually posted.

  Two separate mistakes had to meet for this to work, and each of them on its
  own makes the whole feature silent:

  1. The dispatcher wrote the body under `:message`, and both transports read
     `:notification_message` for the one required text field of their payload
     (Slack's `"text"`, Discord's `"content"`). A declared body therefore
     reached the receipt and never reached the channel.
  2. This release renders a transport's own template file. Landing that under
     one key only would have reproduced the same bug for a rendered body:
     visible in `AshDispatch.Preview`, empty on arrival.

  So the assertion is deliberately not on a content map: it goes through
  `Dispatcher.build_receipt/4` — the function that builds what the receipt
  stores — and then through the transport's own `job_args/3`, which is what
  builds the payload the worker posts.
  """
  use AshDispatch.Test.PreviewCase, async: false

  alias AshDispatch.Channel
  alias AshDispatch.Context
  alias AshDispatch.Dispatcher
  alias AshDispatch.EventResolver
  alias AshDispatch.Test.Preview.BookingUntexted
  alias AshDispatch.Transports.Discord
  alias AshDispatch.Transports.Slack

  @moduletag :capture_log

  defp context do
    %Context{
      event_id: "booking.untexted",
      resource_key: :booking,
      data: EventResolver.sample_data(BookingUntexted),
      variables: %{},
      metadata: %{}
    }
  end

  # The receipt attributes the dispatcher would store, then a receipt-shaped
  # map for `job_args/3`.
  defp receipt_for(transport, channel_overrides \\ %{}) do
    channel =
      struct(
        %Channel{transport: transport, audience: :user, webhook_url: "https://hooks.test/abc"},
        channel_overrides
      )

    {_status, attrs} = Dispatcher.build_receipt(context(), channel, %{}, nil)

    {%{id: Ecto.UUID.generate(), content: attrs.content}, channel}
  end

  describe "Slack" do
    test "the rendered template is the payload's text" do
      {receipt, channel} = receipt_for(:slack)

      assert {:ok, args} = Slack.job_args(receipt, context(), channel)

      assert args["payload"]["text"] =~ "Slack: booking B-UNTEXTED is tomorrow."
    end

    test "and a declared body still wins over the template, all the way out" do
      {receipt, channel} =
        receipt_for(:slack, %{content: %{notification_message: "Declared right here"}})

      assert {:ok, args} = Slack.job_args(receipt, context(), channel)

      assert args["payload"]["text"] == "Declared right here"
    end
  end

  describe "Discord" do
    test "the rendered template is the payload's content" do
      {receipt, channel} = receipt_for(:discord)

      assert {:ok, args} = Discord.job_args(receipt, context(), channel)

      assert args["payload"]["content"] =~ "Discord: booking B-UNTEXTED is tomorrow."
    end

    test "and a declared body still wins" do
      {receipt, channel} =
        receipt_for(:discord, %{content: %{message: "Declared right here"}})

      assert {:ok, args} = Discord.job_args(receipt, context(), channel)

      assert args["payload"]["content"] == "Declared right here"
    end
  end

  describe "the receipt carries the body under both names" do
    test "so the preview and the payload cannot disagree" do
      {receipt, _channel} = receipt_for(:slack)

      assert AshDispatch.ContentMap.get_content(receipt.content, :message) ==
               AshDispatch.ContentMap.get_content(receipt.content, :notification_message)
    end

    test "and an event that declares a body has both too" do
      {receipt, _channel} =
        receipt_for(:slack, %{content: %{message: "Declared right here"}})

      assert AshDispatch.ContentMap.get_content(receipt.content, :notification_message) ==
               "Declared right here"
    end
  end
end
