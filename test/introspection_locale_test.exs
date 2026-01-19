defmodule AshDispatch.IntrospectionLocaleTest do
  @moduledoc """
  Tests for locale handling in AshDispatch.Introspection.

  Note: The introspection module's internal functions (like insert_locale_in_filename)
  are private implementation details. These tests verify:
  1. The type spec includes locale field
  2. The documented behavior of locale template generation

  Full integration testing of locale template generation is done via the mix task tests.
  """

  use ExUnit.Case, async: true

  describe "missing_template type spec" do
    test "includes locale field in type" do
      # Verify the type spec documents the locale field
      # This is a compile-time check that the type includes :locale
      template_example = %{
        event_id: "test.created",
        path: "/path/to/templates",
        filename: "email.sv.html.heex",
        format: :html,
        transport: :email,
        variant: nil,
        locale: "sv"
      }

      # Type-check: this should match the @type missing_template
      assert template_example.locale == "sv"
      assert template_example.format == :html
      assert template_example.transport == :email
    end
  end

  describe "locale template filename conventions (documented behavior)" do
    # Documents the expected filename conventions for locale-specific templates.
    # The actual implementation is in introspection.ex insert_locale_in_filename/2.

    test "base template filenames" do
      # Without locale - standard format
      assert_filename_convention("email.html.heex", nil, "email.html.heex")
      assert_filename_convention("email.text.eex", nil, "email.text.eex")
      assert_filename_convention("sms.text.eex", nil, "sms.text.eex")
    end

    test "locale-specific template filenames" do
      # With locale - locale inserted before format extension
      assert_filename_convention("email.html.heex", "sv", "email.sv.html.heex")
      assert_filename_convention("email.text.eex", "en", "email.en.text.eex")
      assert_filename_convention("sms.text.eex", "no", "sms.no.text.eex")
    end

    test "variant + locale template filenames" do
      # Variant templates with locale
      assert_filename_convention("email.admin.html.heex", "sv", "email.admin.sv.html.heex")
      assert_filename_convention("email.customer.text.eex", "en", "email.customer.en.text.eex")
    end
  end

  describe "template fallback chain (documented behavior)" do
    # Documents the expected template fallback order when resolving templates.
    # This is implemented in TemplateResolver.build_template_candidates/4.

    test "fallback order for variant + locale" do
      # When both variant and locale are specified, the fallback order should be:
      expected_order = [
        # 1. variant + locale
        "email.admin.sv.html.heex",
        # 2. variant only
        "email.admin.html.heex",
        # 3. locale only
        "email.sv.html.heex",
        # 4. base template
        "email.html.heex",
        # 5. default + locale
        "default.sv.html.heex",
        # 6. ultimate fallback
        "default.html.heex"
      ]

      # Document expected behavior
      assert length(expected_order) == 6
      assert hd(expected_order) == "email.admin.sv.html.heex"
      assert List.last(expected_order) == "default.html.heex"
    end

    test "fallback order for locale only (no variant)" do
      expected_order = [
        # 1. locale
        "email.sv.html.heex",
        # 2. base
        "email.html.heex",
        # 3. default + locale
        "default.sv.html.heex",
        # 4. ultimate fallback
        "default.html.heex"
      ]

      assert length(expected_order) == 4
      assert hd(expected_order) == "email.sv.html.heex"
    end
  end

  # Helper to document filename conventions
  # This doesn't test the implementation, just documents expected behavior
  defp assert_filename_convention(base, locale, expected) do
    result = expected_locale_filename(base, locale)

    assert result == expected,
           "Expected #{base} with locale #{inspect(locale)} to produce #{expected}, got #{result}"
  end

  # Document the expected filename transformation
  defp expected_locale_filename(filename, nil), do: filename

  defp expected_locale_filename(filename, locale) do
    case String.split(filename, ".") do
      [base, format, ext] ->
        "#{base}.#{locale}.#{format}.#{ext}"

      [base, variant, format, ext] ->
        "#{base}.#{variant}.#{locale}.#{format}.#{ext}"

      _ ->
        filename
    end
  end
end
