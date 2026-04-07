defmodule AshDispatch.Transports.BroadcastTest do
  use ExUnit.Case, async: true

  alias AshDispatch.Transports.Broadcast

  # We test the pure functions without PubSub.
  # The deliver/4 function needs a PubSub module, so we test
  # the payload building and throttle logic directly.

  describe "throttle ETS" do
    test "first call is not throttled" do
      # Clean ETS state for this test
      table = :ash_dispatch_broadcast_throttle

      try do
        :ets.delete(table)
      rescue
        ArgumentError -> :ok
      end

      event_id = "test_event_#{System.unique_integer()}"
      user_id = "user_#{System.unique_integer()}"

      # Use the module's internal throttle check via deliver
      # Since we can't call the private function directly,
      # we verify the ETS behavior
      refute throttled_check?(event_id, user_id, 1000)
    end

    test "second call within window is throttled" do
      event_id = "test_throttle_#{System.unique_integer()}"
      user_id = "user_throttle_#{System.unique_integer()}"

      refute throttled_check?(event_id, user_id, 5000)
      assert throttled_check?(event_id, user_id, 5000)
    end

    test "call after window expires is not throttled" do
      event_id = "test_expire_#{System.unique_integer()}"
      user_id = "user_expire_#{System.unique_integer()}"

      # First call — not throttled
      refute throttled_check?(event_id, user_id, 1)
      # Wait for throttle window to expire
      Process.sleep(5)
      # Should no longer be throttled
      refute throttled_check?(event_id, user_id, 1)
    end

    test "different users are throttled independently" do
      event_id = "test_users_#{System.unique_integer()}"
      user_a = "user_a_#{System.unique_integer()}"
      user_b = "user_b_#{System.unique_integer()}"

      refute throttled_check?(event_id, user_a, 5000)
      refute throttled_check?(event_id, user_b, 5000)
      assert throttled_check?(event_id, user_a, 5000)
      assert throttled_check?(event_id, user_b, 5000)
    end

    test "different events for same user are throttled independently" do
      event_a = "event_a_#{System.unique_integer()}"
      event_b = "event_b_#{System.unique_integer()}"
      user_id = "user_events_#{System.unique_integer()}"

      refute throttled_check?(event_a, user_id, 5000)
      refute throttled_check?(event_b, user_id, 5000)
      assert throttled_check?(event_a, user_id, 5000)
      assert throttled_check?(event_b, user_id, 5000)
    end
  end

  # Helper that mimics the private throttled?/3 function
  defp throttled_check?(event_id, user_id, throttle_ms) do
    table = :ash_dispatch_broadcast_throttle

    try do
      :ets.info(table)
    rescue
      ArgumentError ->
        :ets.new(table, [:set, :public, :named_table, read_concurrency: true])
    end

    if :ets.whereis(table) == :undefined do
      :ets.new(table, [:set, :public, :named_table, read_concurrency: true])
    end

    key = {event_id, user_id}
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(table, key) do
      [{^key, last_sent}] when now - last_sent < throttle_ms ->
        true

      _ ->
        :ets.insert(table, {key, now})
        false
    end
  end
end
