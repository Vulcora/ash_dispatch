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

  describe "cutoffs/1" do
    setup do
      saved =
        for key <- [:scrub_after_hours, :scrub_stranded_after_hours],
            do: {key, Application.get_env(:ash_dispatch, key)}

      on_exit(fn ->
        for {key, value} <- saved do
          if is_nil(value),
            do: Application.delete_env(:ash_dispatch, key),
            else: Application.put_env(:ash_dispatch, key, value)
        end
      end)
    end

    defp timmar_bakat(nu, tid), do: DateTime.diff(nu, tid, :hour)

    test "the defaults: a day, and a week for what never reached an end" do
      nu = DateTime.utc_now()
      {cutoff, stranded} = ScrubSensitiveContent.cutoffs(nu)

      assert timmar_bakat(nu, cutoff) == 24
      assert timmar_bakat(nu, stranded) == 7 * 24
    end

    test "the cap is configurable" do
      Application.put_env(:ash_dispatch, :scrub_stranded_after_hours, 48)
      nu = DateTime.utc_now()

      assert {_, stranded} = ScrubSensitiveContent.cutoffs(nu)
      assert timmar_bakat(nu, stranded) == 48
    end

    test "the cap is never shorter than the window" do
      Application.put_env(:ash_dispatch, :scrub_after_hours, 100)
      Application.put_env(:ash_dispatch, :scrub_stranded_after_hours, 10)
      nu = DateTime.utc_now()

      assert {_, stranded} = ScrubSensitiveContent.cutoffs(nu)
      assert timmar_bakat(nu, stranded) == 100
    end
  end

  describe "scrub_query/4" do
    setup do
      nu = DateTime.utc_now()
      query = ScrubSensitiveContent.scrub_query("receipts", ["ticket.otp_issued"], nu, nu)

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
