defmodule AshDispatch.Test.RecipientsViaModule.PubSub do
  @moduledoc false
  # Records every broadcast on the test process, so a dispatch that reached a
  # recipient can be told apart from one that resolved nobody.
  def broadcast(topic, event, payload) do
    case Application.get_env(:ash_dispatch, :capture_pid) do
      pid when is_pid(pid) -> send(pid, {:broadcast, topic, event, payload})
      _ -> :ok
    end

    :ok
  end
end

defmodule AshDispatch.Test.RecipientsViaModule.Unregistered do
  @moduledoc false
  # An event module that is on no resource's `dispatch` DSL: the registry has
  # never heard of it, and the only thing that names it is the `:module` key of
  # the event config handed to `Dispatcher.dispatch_channel/3`.
  use AshDispatch.Event

  @impl true
  def id, do: "recipients_via_module.unregistered"

  @impl true
  def recipients(%{data: data}, _channel), do: Map.get(data, :participants, [])
end

defmodule AshDispatch.Dispatch.RecipientsViaEventModuleTest do
  @moduledoc """
  An event module passed explicitly as `event_config[:module]` resolves the
  recipients, exactly as one found in the event registry does.

  Until this fix `Dispatcher.resolve_event_module/2` ignored its event config
  and only asked `EventResolver.find_module(context.event_id)`, so an event
  module the registry does not know about never had its `recipients/2` called —
  the dispatch fell through to audience-based resolution and reached nobody.
  `channel_should_send?/3` had always read `event_config[:module]` directly,
  so the same config was trusted for the event's guard and not for its
  recipients.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AshDispatch.Channel
  alias AshDispatch.Context
  alias AshDispatch.Dispatcher
  alias AshDispatch.Test.Meeting
  alias AshDispatch.Test.RecipientsViaModule.PubSub
  alias AshDispatch.Test.RecipientsViaModule.Unregistered

  @meeting_otp_app :ash_dispatch_meeting_test

  @env [
    otp_app: nil,
    pubsub_module: PubSub,
    channel_topic: "user",
    user_module: nil,
    audiences: nil,
    eligible_recipient: nil,
    user_preference: nil,
    capture_pid: nil
  ]

  @channel %Channel{transport: :broadcast, audience: :user}

  setup do
    previous = Enum.map(@env, fn {key, _} -> {key, Application.fetch_env(:ash_dispatch, key)} end)
    previous_domains = Application.fetch_env(@meeting_otp_app, :ash_domains)

    Enum.each(@env, fn
      {key, nil} -> Application.delete_env(:ash_dispatch, key)
      {key, value} -> Application.put_env(:ash_dispatch, key, value)
    end)

    Application.put_env(:ash_dispatch, :capture_pid, self())

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:ash_dispatch, key, value)
        {key, :error} -> Application.delete_env(:ash_dispatch, key)
      end)

      case previous_domains do
        {:ok, value} -> Application.put_env(@meeting_otp_app, :ash_domains, value)
        :error -> Application.delete_env(@meeting_otp_app, :ash_domains)
      end
    end)

    :ok
  end

  describe "an event module the registry does not know" do
    test "resolves the recipients, and they get the notification" do
      anna = user("anna")

      context = context("recipients_via_module.unregistered", [anna])
      event_config = %{module: Unregistered}

      assert {_context, [^anna]} = Dispatcher.recipients_for(context, @channel, event_config)

      assert {:ok, _} = Dispatcher.dispatch_channel(context, @channel, event_config)

      assert_received {:broadcast, topic, _event, _payload}
      assert topic == "user:#{anna.id}"
    end
  end

  describe "an event module the registry does know" do
    test "still resolves the recipients, with no :module in the event config" do
      register_meeting_domain!()
      bo = user("bo")

      context = context("meeting.updated", [bo])

      assert {_context, [^bo]} = Dispatcher.recipients_for(context, @channel, %{})

      assert {:ok, _} = Dispatcher.dispatch_channel(context, @channel, %{})

      assert_received {:broadcast, topic, _event, _payload}
      assert topic == "user:#{bo.id}"

      # And with the module in the config, the shape the DSL-built config
      # carries: the same recipients, by the other road.
      assert {_context, [^bo]} =
               Dispatcher.recipients_for(context, @channel, %{module: Meeting.Updated})
    end
  end

  describe "no :module and no registry entry" do
    test "falls through to audience-based resolution, as before" do
      cilla = user("cilla")
      context = context("recipients_via_module.nobodys_event", [cilla])

      log =
        capture_log(fn ->
          assert {_context, []} = Dispatcher.recipients_for(context, @channel, %{})

          assert {:error, :all_dispatches_failed} =
                   Dispatcher.dispatch_channel(context, @channel, %{})
        end)

      assert log =~ "No :user_module configured"
      refute_received {:broadcast, _topic, _event, _payload}
    end
  end

  defp register_meeting_domain! do
    Application.put_env(:ash_dispatch, :otp_app, @meeting_otp_app)
    Application.put_env(@meeting_otp_app, :ash_domains, [Meeting.Domain])
  end

  defp context(event_id, participants) do
    %Context{
      event_id: event_id,
      data: %{participants: participants},
      variables: %{}
    }
  end

  defp user(name),
    do: %{
      id: Ash.UUID.generate(),
      email: "#{name}-#{System.unique_integer([:positive])}@example.com"
    }
end
