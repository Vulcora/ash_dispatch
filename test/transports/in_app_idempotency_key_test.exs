defmodule AshDispatch.Transports.InAppIdempotencyKeyTest do
  @moduledoc """
  The in-app idempotency key must identify the OCCURRENCE, not the recipient.

  Until 0.6.11 it always came from `extract_resource_id/1`, which takes the
  first value in `data` carrying a binary `:id`. When `data` carries both the
  recipient and the thing that happened, the recipient can win — and then the
  event is deliverable exactly once per recipient, ever. Seen in prod on a
  "your goal was reached" event: one row in the whole table, and every later
  goal collided with it.
  """

  use ExUnit.Case, async: true

  alias AshDispatch.Channel
  alias AshDispatch.Context
  alias AshDispatch.Transports.InApp

  @user %{id: "11111111-1111-1111-1111-111111111111"}
  @goal %{id: "22222222-2222-2222-2222-222222222222", metric: :meetings}
  @recipient "33333333-3333-3333-3333-333333333333"

  defp channel(opts \\ []) do
    struct!(
      Channel,
      Keyword.merge([transport: :in_app, audience: :user], opts)
    )
  end

  defp context(data) do
    %Context{event_id: "user.goal_reached", data: data}
  end

  test "idempotency_source names which record identifies the occurrence" do
    key =
      InApp.idempotency_key(
        channel(idempotency_source: :goal),
        context(%{user: @user, goal: @goal}),
        @recipient
      )

    assert key == "user.goal_reached:#{@goal.id}:user:#{@recipient}"
  end

  test "two occurrences for the same recipient get different keys" do
    other_goal = %{id: "44444444-4444-4444-4444-444444444444"}
    ch = channel(idempotency_source: :goal)

    first = InApp.idempotency_key(ch, context(%{user: @user, goal: @goal}), @recipient)
    second = InApp.idempotency_key(ch, context(%{user: @user, goal: other_goal}), @recipient)

    refute first == second
  end

  test "without idempotency_source the old heuristic still stands" do
    key = InApp.idempotency_key(channel(), context(%{user: @user}), @recipient)

    assert key == "user.goal_reached:#{@user.id}:user:#{@recipient}"
  end

  test "a source naming a bare id string is taken as the id" do
    key =
      InApp.idempotency_key(
        channel(idempotency_source: :goal_id),
        context(%{user: @user, goal_id: @goal.id}),
        @recipient
      )

    assert key == "user.goal_reached:#{@goal.id}:user:#{@recipient}"
  end

  # A source pointing at nothing must not silently fall back to the recipient —
  # that is the bug this option exists to prevent, and a silent fallback would
  # reintroduce it exactly where the author asked for it not to happen.
  test "a source that resolves to nothing drops the segment, it does not fall back" do
    key =
      InApp.idempotency_key(
        channel(idempotency_source: :goal),
        context(%{user: @user}),
        @recipient
      )

    assert key == "user.goal_reached:user:#{@recipient}"
  end

  test "the audience segment still separates two audiences for one user" do
    ch = fn audience -> channel(audience: audience, idempotency_source: :goal) end
    data = context(%{user: @user, goal: @goal})

    refute InApp.idempotency_key(ch.(:user), data, @recipient) ==
             InApp.idempotency_key(ch.(:admin), data, @recipient)
  end
end
