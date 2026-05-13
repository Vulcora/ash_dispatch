defmodule AshDispatch.TemplateResolverHtmlEscapeTest do
  @moduledoc """
  End-to-end tests for the safe-by-default HTML escape behavior in
  `TemplateResolver`.

  The preprocessor auto-wraps `{@var}` expansions in
  `AshDispatch.SafeRender.escape/1` for HTML formats so user-controlled
  assigns can't inject markup into the rendered email body. The escape
  can be bypassed explicitly via `{raw @safe_html}` for trusted content.

  Text formats (`format: :text`, sms templates, etc.) are unaffected and
  emit `<%= @var %>` plain.
  """

  use ExUnit.Case, async: true

  alias AshDispatch.TemplateResolver

  defp with_temp_templates(templates, fun) do
    tmp_dir = System.tmp_dir!()
    test_dir = Path.join(tmp_dir, "ash_dispatch_escape_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(test_dir)

    try do
      Enum.each(templates, fn {filename, content} ->
        File.write!(Path.join(test_dir, filename), content)
      end)

      fun.(test_dir)
    after
      File.rm_rf!(test_dir)
    end
  end

  describe ":html format auto-escapes {@var}" do
    test "neutralizes <script> in plain text assign" do
      templates = [
        {"email.html.heex", "<p>Hej {@name}</p>"}
      ]

      with_temp_templates(templates, fn dir ->
        {:ok, html} =
          TemplateResolver.render(
            template_path: dir,
            format: :html,
            transport: :email,
            assigns: %{name: "<script>alert('XSS')</script>"}
          )

        assert html =~ "&lt;script&gt;alert(&#39;XSS&#39;)&lt;/script&gt;"
        refute html =~ "<script>"
      end)
    end

    test "escapes attribute-injection attempts" do
      templates = [
        {"email.html.heex", ~s|<a href="/x">{@label}</a>|}
      ]

      with_temp_templates(templates, fn dir ->
        {:ok, html} =
          TemplateResolver.render(
            template_path: dir,
            format: :html,
            transport: :email,
            assigns: %{label: ~s|" onclick="alert(1)|}
          )

        # `"` chars escaped → can't close the surrounding href quote, so
        # the literal "onclick" string ends up as inert content between
        # escaped quotes rather than a fresh attribute.
        assert html =~ "&quot; onclick=&quot;alert(1)"
      end)
    end

    test "preserves harmless content unchanged" do
      templates = [
        {"email.html.heex", "<p>{@greeting}</p>"}
      ]

      with_temp_templates(templates, fn dir ->
        {:ok, html} =
          TemplateResolver.render(
            template_path: dir,
            format: :html,
            transport: :email,
            assigns: %{greeting: "Hej Anna 🇸🇪"}
          )

        assert html =~ "Hej Anna 🇸🇪"
      end)
    end

    test "nil assign renders as empty (instead of literal 'nil')" do
      templates = [
        {"email.html.heex", "<p>[{@missing}]</p>"}
      ]

      with_temp_templates(templates, fn dir ->
        {:ok, html} =
          TemplateResolver.render(
            template_path: dir,
            format: :html,
            transport: :email,
            assigns: %{missing: nil}
          )

        assert html =~ "[]"
        refute html =~ "nil"
      end)
    end

    test "explicit `{raw(@x)}` bypasses escape for trusted markup" do
      templates = [
        {"email.html.heex", "<div>{raw(@trusted_block)}</div>"}
      ]

      with_temp_templates(templates, fn dir ->
        {:ok, html} =
          TemplateResolver.render(
            template_path: dir,
            format: :html,
            transport: :email,
            assigns: %{trusted_block: "<b>bold</b>"}
          )

        assert html =~ "<b>bold</b>"
      end)
    end

    test "explicit `{AshDispatch.SafeRender.raw(@x)}` also bypasses escape" do
      templates = [
        {"email.html.heex", "<div>{AshDispatch.SafeRender.raw(@block)}</div>"}
      ]

      with_temp_templates(templates, fn dir ->
        {:ok, html} =
          TemplateResolver.render(
            template_path: dir,
            format: :html,
            transport: :email,
            assigns: %{block: "<i>italic</i>"}
          )

        assert html =~ "<i>italic</i>"
      end)
    end
  end

  describe ":text format does NOT auto-escape" do
    test "<script> renders verbatim (text wins over HTML)" do
      templates = [
        {"email.text.eex", "Hej {@name}"}
      ]

      with_temp_templates(templates, fn dir ->
        {:ok, text} =
          TemplateResolver.render(
            template_path: dir,
            format: :text,
            transport: :email,
            assigns: %{name: "<script>alert(1)</script>"}
          )

        # In :text format the value passes through unchanged — text/plain
        # has no HTML semantics, so escaping would be wrong.
        assert text =~ "<script>alert(1)</script>"
      end)
    end
  end
end
