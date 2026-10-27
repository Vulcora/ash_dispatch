defmodule AshDispatch.TestHelpersTest do
  @moduledoc ~S"""
  `AshDispatch.Test.render_all/1` and `assert_all_render/1` — the one-line
  "every mail renders" test for apps. The fixtures hold two good events and
  one broken one (`booking.broken`: empty subject, `#{...}` in the HTML, a
  TODO in the text).
  """
  use AshDispatch.Test.PreviewCase, async: false

  @good ["booking.confirmed", "booking.reminder"]

  test "assert_all_render/1 returns how many letters it rendered" do
    # booking.confirmed: one email. booking.reminder: two emails and an
    # in-app channel. Three seeds each.
    assert AshDispatch.Test.assert_all_render(only: @good, seeds: 3) == 12
  end

  test "seeds: a list renders once per seed" do
    assert AshDispatch.Test.assert_all_render(only: ["booking.confirmed"], seeds: [4, 8]) == 2
  end

  test ":transports narrows the rows" do
    assert AshDispatch.Test.assert_all_render(only: @good, transports: [:in_app]) == 1
  end

  test "a broken letter fails with every finding, named" do
    error =
      assert_raise ExUnit.AssertionError, fn ->
        AshDispatch.Test.assert_all_render(only: ["booking.broken"])
      end

    assert error.message =~ "1 of 1 letters would go out broken"
    assert error.message =~ "booking.broken email/user (seed 1)"
    assert error.message =~ "empty subject"
    assert error.message =~ "html_body contains `\#{`"
    assert error.message =~ "text_body contains `TODO`"
    refute error.message =~ "contains `{@`"
  end

  test "render_all/1 returns the letters and their problems" do
    results = AshDispatch.Test.render_all()

    assert Enum.map(results, & &1.row.event_id) |> Enum.uniq() |> Enum.sort() ==
             ["booking.broken", "booking.confirmed", "booking.reminder"]

    assert [broken] = Enum.filter(results, &(&1.problems != []))
    assert broken.row.event_id == "booking.broken"
    assert %AshDispatch.Preview.Rendered{} = broken.rendered
  end

  test ":forbid adds markers of the app's own" do
    error =
      assert_raise ExUnit.AssertionError, fn ->
        AshDispatch.Test.assert_all_render(only: ["booking.confirmed"], forbid: ["confirmed"])
      end

    assert error.message =~ "subject contains `confirmed`"
  end

  test "CSS in a <style> block is not mistaken for template source" do
    html = "<style>@supports (display:grid){@media (min-width:1px){.a{b:c}}}</style><p>ok</p>"

    rendered = %AshDispatch.Preview.Rendered{
      transport: :email,
      subject: "Hello",
      html_body: html,
      text_body: "ok"
    }

    assert AshDispatch.Test.problems_for(rendered) == []
  end

  test "rendering nothing is a failure, not a pass" do
    error =
      assert_raise ExUnit.AssertionError, fn ->
        AshDispatch.Test.assert_all_render(only: ["no.such.event"])
      end

    assert error.message =~ "rendered nothing"
  end
end
