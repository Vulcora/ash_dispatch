defmodule AshDispatch.DispatcherSafelyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AshDispatch.Dispatcher

  @moduletag :capture_log

  test "unknown event returns :ok and logs instead of erroring" do
    log =
      capture_log(fn ->
        assert :ok = Dispatcher.dispatch_safely("does.not_exist", %{}, %{})
      end)

    assert log =~ "dispatch_safely"
  end

  test "raises are absorbed" do
    log =
      capture_log(fn ->
        assert :ok = Dispatcher.dispatch_safely("x", :not_a_map, %{})
      end)

    assert log =~ "raised"
  end
end
