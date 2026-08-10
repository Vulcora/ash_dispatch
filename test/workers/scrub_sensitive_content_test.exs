defmodule AshDispatch.Workers.ScrubSensitiveContentTest do
  # Async disabled: reads Application config for event discovery
  use ExUnit.Case, async: false

  alias AshDispatch.Workers.ScrubSensitiveContent

  @moduletag :capture_log

  describe "sensitive_event_ids/1" do
    test "returns only events declaring sensitive_content: true" do
      ids = ScrubSensitiveContent.sensitive_event_ids(:ash_dispatch_test)

      assert "ticket.otp_issued" in ids
      refute "ticket.created" in ids
      refute "order.created" in ids
    end
  end

  describe "perform/1" do
    test "no sensitive events configured is a no-op :ok" do
      original = Application.get_env(:ash_dispatch, :otp_app)
      Application.put_env(:ash_dispatch, :otp_app, :ash_dispatch_no_such_app)

      on_exit(fn ->
        if original,
          do: Application.put_env(:ash_dispatch, :otp_app, original),
          else: Application.delete_env(:ash_dispatch, :otp_app)
      end)

      assert :ok = ScrubSensitiveContent.perform(%Oban.Job{args: %{}})
    end
  end
end
