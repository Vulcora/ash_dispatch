defmodule AshDispatch.Transports.EmailScheduleTest do
  @moduledoc """
  The channel's `time` → Oban `schedule_in` mapping.

  `{:at, %DateTime{}}` was documented, typed and normalized — and then
  dropped on the floor: the email transport only matched `{:in, seconds}`
  and let everything else fall into a catch-all `0`, so an absolute-time
  channel sent immediately, silently. `Channel.calculate_delay/1`, which
  knows how to compute it, had zero call sites.

  `{:window, map}` never had an implementation at all. It stays immediate
  (removing it would be a breaking change) but now says so in the log.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AshDispatch.Channel
  alias AshDispatch.Transports.Email

  defp channel(time), do: %Channel{transport: :email, audience: :user, time: time}

  describe "schedule_seconds/1 — {:in, seconds}" do
    test "is passed through unchanged" do
      assert Email.schedule_seconds(channel({:in, 300})) == 300
      assert Email.schedule_seconds(channel({:in, 0})) == 0
    end

    test "the struct default (immediate) is 0" do
      assert Email.schedule_seconds(%Channel{transport: :email, audience: :user}) == 0
      assert Email.schedule_seconds(channel(Channel.normalize_time(:immediate))) == 0
    end
  end

  describe "schedule_seconds/1 — {:at, %DateTime{}}" do
    test "an absolute time in the future becomes the delay to that time" do
      at = DateTime.add(DateTime.utc_now(), 7200, :second)

      assert_in_delta Email.schedule_seconds(channel({:at, at})), 7200, 5
    end

    test "an absolute time in the past is clamped to 0, never negative" do
      at = DateTime.add(DateTime.utc_now(), -3600, :second)

      assert Email.schedule_seconds(channel({:at, at})) == 0
    end

    test "an absolute time of now is 0" do
      assert Email.schedule_seconds(channel({:at, DateTime.utc_now()})) == 0
    end

    test "regression: {:at, …} is no longer treated as immediate" do
      at = DateTime.add(DateTime.utc_now(), 86_400, :second)

      refute Email.schedule_seconds(channel({:at, at})) == 0
    end
  end

  describe "schedule_seconds/1 — {:window, map} (deprecated)" do
    setup do
      Channel.reset_window_deprecation_warning()
      on_exit(&Channel.reset_window_deprecation_warning/0)
      :ok
    end

    test "still delivers immediately" do
      assert Email.schedule_seconds(channel({:window, %{start: ~T[09:00:00]}})) == 0
    end

    test "logs a deprecation warning" do
      log =
        capture_log(fn ->
          Email.schedule_seconds(channel({:window, %{start: ~T[09:00:00]}}))
        end)

      assert log =~ "{:window, ...} is deprecated"
      assert log =~ "treated as immediate"
    end

    test "warns only once per boot" do
      capture_log(fn -> Email.schedule_seconds(channel({:window, %{}})) end)

      second =
        capture_log(fn ->
          assert Email.schedule_seconds(channel({:window, %{}})) == 0
        end)

      refute second =~ "deprecated"
    end
  end

  describe "schedule_seconds/1 — unknown shapes" do
    test "anything else is immediate" do
      assert Email.schedule_seconds(channel(:nonsense)) == 0
      assert Email.schedule_seconds(%{transport: :email}) == 0
    end
  end

  describe "Channel.calculate_delay/1" do
    test "{:in, seconds} and :immediate are unchanged" do
      assert Channel.calculate_delay(channel({:in, 300})) == 300
      assert Channel.calculate_delay(channel(:immediate)) == 0
    end

    test "{:at, …} is relative to now and may be negative — the transport clamps" do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      assert Channel.calculate_delay(channel({:at, past})) < 0
      assert Email.schedule_seconds(channel({:at, past})) == 0
    end

    test "{:window, …} is 0" do
      assert Channel.calculate_delay(channel({:window, %{}})) == 0
    end

    test "an unknown shape is 0" do
      assert Channel.calculate_delay(channel(:nonsense)) == 0
      assert Channel.calculate_delay(:not_a_channel) == 0
    end
  end
end
