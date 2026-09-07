defmodule AshDispatch.ChannelIdempotencySourceTest do
  @moduledoc """
  A channel option is only real if it survives every way a channel is built.

  `to_channel_struct/1` has three clauses — the Spark DSL entity, a plain map,
  and the inline keyword list. An option added to one of them is silently nil
  through the others, and the caller who wrote it in the DSL never learns that
  it did nothing.
  """

  use ExUnit.Case, async: true

  alias AshDispatch.Channel
  alias AshDispatch.ChannelResolver

  test "the Spark DSL entity carries it" do
    dsl =
      struct!(AshDispatch.Dsl.Channel,
        transport: :in_app,
        audience: :user,
        idempotency_source: :goal
      )

    assert %Channel{idempotency_source: :goal} = ChannelResolver.to_channel_struct(dsl)
  end

  test "a map carries it" do
    assert %Channel{idempotency_source: :goal} =
             ChannelResolver.to_channel_struct(%{
               transport: :in_app,
               audience: :user,
               idempotency_source: :goal
             })
  end

  test "the inline keyword list carries it" do
    assert %Channel{idempotency_source: :goal} =
             ChannelResolver.to_channel_struct(
               transport: :in_app,
               audience: :user,
               idempotency_source: :goal
             )
  end

  test "unset stays nil in all three shapes" do
    dsl = struct!(AshDispatch.Dsl.Channel, transport: :in_app, audience: :user)

    for channel <- [
          dsl,
          %{transport: :in_app, audience: :user},
          [transport: :in_app, audience: :user]
        ] do
      assert %Channel{idempotency_source: nil} = ChannelResolver.to_channel_struct(channel)
    end
  end
end
