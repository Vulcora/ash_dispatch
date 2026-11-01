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

  describe "scrub_query/3" do
    setup do
      query =
        ScrubSensitiveContent.scrub_query("receipts", ["ticket.otp_issued"], DateTime.utc_now())

      %{query: query}
    end

    test "empties both bodies and removes the copies of them from content", %{query: query} do
      set = Enum.flat_map(query.updates, fn %{expr: [set: set]} -> set end)

      assert set |> Keyword.keys() |> Enum.sort() == [:body_html, :body_text, :content]
      assert {:fragment, _, parts} = set[:content]

      raw = for {:raw, r} <- parts, into: "", do: r
      assert raw =~ "- 'html_body'"
      assert raw =~ "- 'text_body'"
    end

    test "picks up a receipt whose content still holds a body", %{query: query} do
      wheres = Enum.map_join(query.wheres, " ", &Macro.to_string(&1.expr))
      assert wheres =~ "html_body"
      assert wheres =~ "text_body"
    end
  end
end
