defmodule AshDispatch.SafeRenderTest do
  @moduledoc """
  Verifies `AshDispatch.SafeRender.escape/1` correctly neutralizes
  user-controlled values flowing into HTML email templates, and that the
  `raw/1` opt-out passes its value through unchanged.

  See also `template_resolver_html_escape_test.exs` for end-to-end coverage
  via the preprocessor that auto-wraps `{@var}` in HTML format.
  """

  use ExUnit.Case, async: true

  alias AshDispatch.SafeRender

  describe "escape/1" do
    test "escapes <, >, &, \", '" do
      assert SafeRender.escape("<script>alert('XSS')</script>") ==
               "&lt;script&gt;alert(&#39;XSS&#39;)&lt;/script&gt;"
    end

    test "escapes attribute injection" do
      assert SafeRender.escape(~s|" onclick="alert(1)|) ==
               "&quot; onclick=&quot;alert(1)"
    end

    test "preserves unicode and emoji unchanged" do
      assert SafeRender.escape("Hej Anna 🇸🇪") == "Hej Anna 🇸🇪"
    end

    test "nil → empty string (so missing assigns don't render 'nil')" do
      assert SafeRender.escape(nil) == ""
    end

    test "integers and floats are stringified" do
      assert SafeRender.escape(42) == "42"
      assert SafeRender.escape(3.14) == "3.14"
    end

    test "atoms are stringified (no escape needed)" do
      assert SafeRender.escape(:hello) == "hello"
    end

    test "{:safe, iodata} passes through unchanged (Phoenix.HTML interop)" do
      assert SafeRender.escape({:safe, "<b>already escaped</b>"}) ==
               "<b>already escaped</b>"
    end

    test "Date/NaiveDateTime are stringified via String.Chars (no escape needed)" do
      assert SafeRender.escape(~D[2026-05-13]) == "2026-05-13"
      assert SafeRender.escape(~N[2026-05-13 14:30:00]) == "2026-05-13 14:30:00"
    end

    test "raises Protocol.UndefinedError for maps/tuples (loud over silent)" do
      # Lists are not raised against — Elixir treats `[1,2,3]` as a charlist
      # and `to_string/1` returns the 3-byte binary `<<1,2,3>>`. That's a
      # quirk we accept; the test guards against arbitrary structs/maps
      # accidentally landing in template assigns.
      assert_raise Protocol.UndefinedError, fn -> SafeRender.escape(%{a: 1}) end
      assert_raise Protocol.UndefinedError, fn -> SafeRender.escape({:a, :b}) end
    end
  end

  describe "raw/1" do
    test "returns the value unchanged" do
      assert SafeRender.raw("anything") == "anything"
      assert SafeRender.raw(nil) == nil
      assert SafeRender.raw(%{a: 1}) == %{a: 1}
    end

    test "is identity — the preprocessor recognises it and skips escape" do
      # The actual escape-skip behavior lives in
      # `TemplateResolver.render_expression/2`. This unit test asserts
      # only that `raw/1` itself is a passthrough; the integration test
      # verifies the preprocessor end-to-end.
      assert SafeRender.raw("<b>x</b>") == "<b>x</b>"
    end
  end
end
