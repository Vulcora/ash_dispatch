defmodule AshDispatch.TemplateResolverLocaleTest do
  @moduledoc """
  Tests for locale-aware template resolution in AshDispatch.TemplateResolver.

  These tests verify the locale fallback chain:
  1. variant+locale (e.g., email.admin.sv.html.heex)
  2. variant only (e.g., email.admin.html.heex)
  3. locale only (e.g., email.sv.html.heex)
  4. base template (e.g., email.html.heex)
  5. default+locale (e.g., default.sv.html.heex)
  6. default fallback (e.g., default.html.heex)
  """

  use ExUnit.Case, async: true

  alias AshDispatch.TemplateResolver

  # Helper to create a temporary template directory with specific templates
  defp with_temp_templates(templates, fun) do
    tmp_dir = System.tmp_dir!()
    test_dir = Path.join(tmp_dir, "ash_dispatch_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(test_dir)

    try do
      # Create template files
      Enum.each(templates, fn {filename, content} ->
        path = Path.join(test_dir, filename)
        File.write!(path, content)
      end)

      fun.(test_dir)
    after
      File.rm_rf!(test_dir)
    end
  end

  describe "build_template_candidates/4" do
    # We test the private function behavior through render/1

    test "locale-only template is found" do
      templates = [
        {"email.sv.html.heex", "<p>Swedish: <%= @message %></p>"},
        {"email.html.heex", "<p>Default: <%= @message %></p>"}
      ]

      with_temp_templates(templates, fn dir ->
        result =
          TemplateResolver.render(
            template_path: dir,
            format: :html,
            transport: :email,
            locale: "sv",
            assigns: %{message: "Hej!"}
          )

        assert {:ok, html} = result
        assert html =~ "Swedish: Hej!"
      end)
    end

    test "falls back to base template when locale template missing" do
      templates = [
        {"email.html.heex", "<p>Default: <%= @message %></p>"}
      ]

      with_temp_templates(templates, fn dir ->
        result =
          TemplateResolver.render(
            template_path: dir,
            format: :html,
            transport: :email,
            locale: "sv",
            assigns: %{message: "Hello!"}
          )

        assert {:ok, html} = result
        assert html =~ "Default: Hello!"
      end)
    end

    test "variant+locale template takes priority" do
      templates = [
        {"email.admin.sv.html.heex", "<p>Admin Swedish: <%= @message %></p>"},
        {"email.admin.html.heex", "<p>Admin Default: <%= @message %></p>"},
        {"email.sv.html.heex", "<p>Swedish: <%= @message %></p>"},
        {"email.html.heex", "<p>Default: <%= @message %></p>"}
      ]

      with_temp_templates(templates, fn dir ->
        result =
          TemplateResolver.render(
            template_path: dir,
            format: :html,
            transport: :email,
            variant: "admin",
            locale: "sv",
            assigns: %{message: "Hej Admin!"}
          )

        assert {:ok, html} = result
        assert html =~ "Admin Swedish: Hej Admin!"
      end)
    end

    test "variant without locale falls back correctly" do
      templates = [
        {"email.admin.html.heex", "<p>Admin Default: <%= @message %></p>"},
        {"email.sv.html.heex", "<p>Swedish: <%= @message %></p>"},
        {"email.html.heex", "<p>Default: <%= @message %></p>"}
      ]

      with_temp_templates(templates, fn dir ->
        # With variant but without matching variant+locale
        result =
          TemplateResolver.render(
            template_path: dir,
            format: :html,
            transport: :email,
            variant: "admin",
            locale: "sv",
            assigns: %{message: "Test"}
          )

        assert {:ok, html} = result
        # Should fall back to variant without locale
        assert html =~ "Admin Default: Test"
      end)
    end

    test "nil locale skips locale-specific templates" do
      templates = [
        {"email.sv.html.heex", "<p>Swedish: <%= @message %></p>"},
        {"email.html.heex", "<p>Default: <%= @message %></p>"}
      ]

      with_temp_templates(templates, fn dir ->
        result =
          TemplateResolver.render(
            template_path: dir,
            format: :html,
            transport: :email,
            locale: nil,
            assigns: %{message: "Test"}
          )

        assert {:ok, html} = result
        assert html =~ "Default: Test"
      end)
    end

    test "text format with locale" do
      templates = [
        {"email.sv.text.eex", "Swedish text: <%= @message %>"},
        {"email.text.eex", "Default text: <%= @message %>"}
      ]

      with_temp_templates(templates, fn dir ->
        result =
          TemplateResolver.render(
            template_path: dir,
            format: :text,
            transport: :email,
            locale: "sv",
            assigns: %{message: "Hej!"}
          )

        assert {:ok, text} = result
        assert text =~ "Swedish text: Hej!"
      end)
    end

    test "sms transport with locale" do
      templates = [
        {"sms.en.text.eex", "English SMS: <%= @message %>"},
        {"sms.text.eex", "Default SMS: <%= @message %>"}
      ]

      with_temp_templates(templates, fn dir ->
        result =
          TemplateResolver.render(
            template_path: dir,
            format: :text,
            transport: :sms,
            locale: "en",
            assigns: %{message: "Hello!"}
          )

        assert {:ok, text} = result
        assert text =~ "English SMS: Hello!"
      end)
    end
  end

  describe "locale fallback chain" do
    test "full fallback chain with all templates present" do
      # Test the complete priority order
      templates = [
        {"email.admin.sv.html.heex", "<p>1. variant+locale</p>"},
        {"email.admin.html.heex", "<p>2. variant only</p>"},
        {"email.sv.html.heex", "<p>3. locale only</p>"},
        {"email.html.heex", "<p>4. base</p>"},
        {"default.sv.html.heex", "<p>5. default+locale</p>"},
        {"default.html.heex", "<p>6. default fallback</p>"}
      ]

      with_temp_templates(templates, fn dir ->
        # With variant and locale - should get variant+locale
        result =
          TemplateResolver.render(
            template_path: dir,
            format: :html,
            transport: :email,
            variant: "admin",
            locale: "sv",
            assigns: %{}
          )

        assert {:ok, html} = result
        assert html =~ "1. variant+locale"
      end)
    end

    test "fallback when variant+locale missing" do
      templates = [
        {"email.admin.html.heex", "<p>2. variant only</p>"},
        {"email.sv.html.heex", "<p>3. locale only</p>"},
        {"email.html.heex", "<p>4. base</p>"}
      ]

      with_temp_templates(templates, fn dir ->
        result =
          TemplateResolver.render(
            template_path: dir,
            format: :html,
            transport: :email,
            variant: "admin",
            locale: "sv",
            assigns: %{}
          )

        assert {:ok, html} = result
        # Should fall back to variant only (priority 2)
        assert html =~ "2. variant only"
      end)
    end

    test "fallback when only base template exists" do
      templates = [
        {"email.html.heex", "<p>4. base</p>"}
      ]

      with_temp_templates(templates, fn dir ->
        result =
          TemplateResolver.render(
            template_path: dir,
            format: :html,
            transport: :email,
            variant: "admin",
            locale: "sv",
            assigns: %{}
          )

        assert {:ok, html} = result
        assert html =~ "4. base"
      end)
    end
  end

  describe "error handling" do
    test "returns error when no template found" do
      with_temp_templates([], fn dir ->
        result =
          TemplateResolver.render(
            template_path: dir,
            format: :html,
            transport: :email,
            locale: "sv",
            assigns: %{}
          )

        assert {:error, _} = result
      end)
    end
  end
end
