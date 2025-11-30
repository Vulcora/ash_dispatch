defmodule AshDispatch.ChannelResolverTest do
  use ExUnit.Case, async: true

  alias AshDispatch.{Channel, ChannelResolver, Context}

  describe "to_channel_struct/1" do
    test "returns Channel struct unchanged" do
      channel = %Channel{transport: :email, audience: :user}
      assert ChannelResolver.to_channel_struct(channel) == channel
    end

    test "converts map to Channel struct" do
      channel_map = %{transport: :email, audience: :admin, variant: "summary"}
      result = ChannelResolver.to_channel_struct(channel_map)

      assert %Channel{} = result
      assert result.transport == :email
      assert result.audience == :admin
      assert result.variant == "summary"
      assert result.time == {:in, 0}
      assert result.policy == :always
    end

    test "converts keyword list to Channel struct" do
      channel_kw = [transport: :sms, audience: :user, time: {:in, 60}]
      result = ChannelResolver.to_channel_struct(channel_kw)

      assert %Channel{} = result
      assert result.transport == :sms
      assert result.audience == :user
      assert result.time == {:in, 60}
    end

    test "converts DSL channel struct to runtime Channel" do
      dsl_channel = %AshDispatch.Dsl.Channel{
        transport: :email,
        audience: :admin,
        variant: "digest",
        time: {:in, 300}
      }

      result = ChannelResolver.to_channel_struct(dsl_channel)

      assert %Channel{} = result
      assert result.transport == :email
      assert result.audience == :admin
      assert result.variant == "digest"
      assert result.time == {:in, 300}
    end

    test "handles delay key for time" do
      channel_map = %{transport: :email, audience: :user, delay: {:in, 120}}
      result = ChannelResolver.to_channel_struct(channel_map)

      assert result.time == {:in, 120}
    end

    test "handles integer seconds for time" do
      channel_map = %{transport: :email, audience: :user, time: 30}
      result = ChannelResolver.to_channel_struct(channel_map)

      assert result.time == {:in, 30}
    end

    test "converts content and metadata lists to maps" do
      channel_kw = [
        transport: :email,
        audience: :user,
        content: [key: "value"],
        metadata: [foo: "bar"]
      ]

      result = ChannelResolver.to_channel_struct(channel_kw)

      assert result.content == %{key: "value"}
      assert result.metadata == %{foo: "bar"}
    end
  end

  describe "get_module_channels/2" do
    test "returns empty list when module is nil" do
      context = %Context{event_id: "test", data: %{}, metadata: %{}}
      assert ChannelResolver.get_module_channels(nil, context) == []
    end

    test "returns empty list when module doesn't export channels/1" do
      defmodule NoChannelsModule do
      end

      context = %Context{event_id: "test", data: %{}, metadata: %{}}
      assert ChannelResolver.get_module_channels(NoChannelsModule, context) == []
    end

    test "calls module channels/1 callback" do
      defmodule WithChannelsModule do
        def channels(_context) do
          [%AshDispatch.Channel{transport: :email, audience: :user}]
        end
      end

      context = %Context{event_id: "test", data: %{}, metadata: %{}}
      result = ChannelResolver.get_module_channels(WithChannelsModule, context)

      assert [%Channel{transport: :email, audience: :user}] = result
    end

    @tag :capture_log
    test "handles errors in channels/1 gracefully" do
      defmodule ErrorChannelsModule do
        def channels(_context) do
          raise "boom"
        end
      end

      context = %Context{event_id: "test", data: %{}, metadata: %{}}
      assert ChannelResolver.get_module_channels(ErrorChannelsModule, context) == []
    end
  end

  describe "get_dsl_channels/2" do
    test "returns empty list when event_id is nil" do
      assert ChannelResolver.get_dsl_channels(nil, []) == []
    end

    test "uses pre-loaded dsl_channels option" do
      dsl_channels = [
        %{transport: :email, audience: :user},
        %{transport: :email, audience: :admin}
      ]

      result = ChannelResolver.get_dsl_channels("test.event", dsl_channels: dsl_channels)

      assert length(result) == 2
      assert Enum.all?(result, &match?(%Channel{}, &1))
    end

    test "converts pre-loaded channels to Channel structs" do
      dsl_channels = [[transport: :sms, audience: :user, time: {:in, 60}]]

      [result] = ChannelResolver.get_dsl_channels("test.event", dsl_channels: dsl_channels)

      assert result.transport == :sms
      assert result.audience == :user
      assert result.time == {:in, 60}
    end
  end

  describe "resolve/4" do
    test "returns DSL channels when available (dsl_first strategy)" do
      defmodule ResolveTestModule do
        def channels(_context) do
          [%AshDispatch.Channel{transport: :sms, audience: :user}]
        end
      end

      context = %Context{event_id: "test.event", data: %{}, metadata: %{}}
      dsl_channels = [%{transport: :email, audience: :admin}]

      result =
        ChannelResolver.resolve(
          "test.event",
          ResolveTestModule,
          context,
          dsl_channels: dsl_channels
        )

      # Should use DSL channels, not module channels
      assert [%Channel{transport: :email, audience: :admin}] = result
    end

    test "falls back to module channels when no DSL channels" do
      defmodule FallbackTestModule do
        def channels(_context) do
          [%AshDispatch.Channel{transport: :discord, audience: :admin}]
        end
      end

      context = %Context{event_id: "test.event", data: %{}, metadata: %{}}

      result =
        ChannelResolver.resolve(
          "test.event",
          FallbackTestModule,
          context,
          dsl_channels: []
        )

      assert [%Channel{transport: :discord, audience: :admin}] = result
    end

    test "merge strategy combines both sources" do
      defmodule MergeTestModule do
        def channels(_context) do
          [%AshDispatch.Channel{transport: :sms, audience: :user}]
        end
      end

      context = %Context{event_id: "test.event", data: %{}, metadata: %{}}
      dsl_channels = [%{transport: :email, audience: :admin}]

      result =
        ChannelResolver.resolve(
          "test.event",
          MergeTestModule,
          context,
          dsl_channels: dsl_channels,
          strategy: :merge
        )

      assert length(result) == 2
      transports = Enum.map(result, & &1.transport)
      assert :email in transports
      assert :sms in transports
    end
  end

  describe "has_transport?/5" do
    test "returns true when channels include transport type" do
      defmodule HasEmailModule do
        def channels(_context) do
          [%AshDispatch.Channel{transport: :email, audience: :user}]
        end
      end

      context = %Context{event_id: "test", data: %{}, metadata: %{}}

      assert ChannelResolver.has_transport?("test", HasEmailModule, context, :email)
      refute ChannelResolver.has_transport?("test", HasEmailModule, context, :sms)
    end

    test "checks DSL channels first" do
      defmodule OnlySmsModule do
        def channels(_context) do
          [%AshDispatch.Channel{transport: :sms, audience: :user}]
        end
      end

      context = %Context{event_id: "test", data: %{}, metadata: %{}}
      dsl_channels = [%{transport: :email, audience: :admin}]

      # With DSL channels (email), should find email but not sms
      assert ChannelResolver.has_transport?(
               "test",
               OnlySmsModule,
               context,
               :email,
               dsl_channels: dsl_channels
             )

      refute ChannelResolver.has_transport?(
               "test",
               OnlySmsModule,
               context,
               :sms,
               dsl_channels: dsl_channels
             )
    end
  end
end
