defmodule AshDispatch.TemplateResolver do
  @moduledoc """
  Resolves and renders HEEx/EEx templates for events with fallback chain.

  Supports both development (file-based) and production (compiled) templates.

  ## Resolution Strategy (Fallback Chain)

  Templates are resolved in priority order:

  1. **Variant-specific:** `email.admin.html.heex` (if `variant: "admin"`)
  2. **Transport-specific:** `email.html.heex` (default for transport)
  3. **Generic fallback:** `default.html.heex` (if exists)
  4. **Error:** `:template_not_found`

  ## Template Formats

  - **HEEx** (`.html.heex`) - HTML templates with HEEx attribute syntax
  - **EEx** (`.text.eex`) - Plain text templates with EEx

  ## Examples

      # Default email template
      TemplateResolver.render(
        event_dir: __DIR__,
        transport: :email,
        format: :html,
        assigns: %{user: user, order: order}
      )
      # → Looks for: email.html.heex → default.html.heex

      # Admin-specific variant
      TemplateResolver.render(
        event_dir: __DIR__,
        variant: "admin",
        transport: :email,
        format: :html,
        assigns: assigns
      )
      # → Looks for: email.admin.html.heex → email.html.heex → default.html.heex
  """

  require EEx

  @doc """
  Renders a template with the given options.

  ## Options

  * `:event_dir` - Optional in production. The directory of the event module (use `__DIR__`)
  * `:event_module` - Optional. The event module with compiled templates
  * `:format` - Required. Either `:html` or `:text`
  * `:transport` - Required. The transport type (e.g., `:email`)
  * `:variant` - Optional. A variant hint like "admin" or "user"
  * `:assigns` - Required. Map of variables available in template as @variable

  ## Returns

  * `{:ok, rendered_string}` - Successfully rendered template
  * `{:error, :template_not_found}` - No matching template found
  * `{:error, reason}` - Rendering error
  """
  def render(opts) do
    event_module = Keyword.get(opts, :event_module)
    event_dir = Keyword.get(opts, :event_dir)
    format = Keyword.fetch!(opts, :format)
    transport = Keyword.fetch!(opts, :transport)
    variant = Keyword.get(opts, :variant)
    assigns = Keyword.fetch!(opts, :assigns)

    # Try compiled templates first (production), fall back to files (development)
    cond do
      event_module && function_exported?(event_module, :__compiled_templates__, 0) ->
        render_from_compiled(event_module, transport, variant, format, assigns)

      event_dir ->
        render_from_files(event_dir, transport, variant, format, assigns)

      true ->
        {:error, :template_not_found}
    end
  end

  # Render from compiled templates (production)
  defp render_from_compiled(event_module, transport, variant, format, assigns) do
    templates = event_module.__compiled_templates__()
    extension = extension_for(format)

    candidates = [
      variant && "#{transport}.#{variant}.#{extension}",
      "#{transport}.#{extension}",
      "default.#{extension}"
    ]

    case Enum.find_value(candidates, fn
           nil -> nil
           filename -> Map.get(templates, filename)
         end) do
      nil ->
        {:error, :template_not_found}

      template_content ->
        render_template_content(template_content, assigns, format)
    end
  end

  # Render from files (development)
  defp render_from_files(event_dir, transport, variant, format, assigns) do
    template_path = resolve_template(event_dir, transport, variant, format)

    case template_path do
      {:ok, path} ->
        template_content = File.read!(path)
        render_template_content(template_content, assigns, format)

      :error ->
        {:error, :template_not_found}
    end
  rescue
    error ->
      {:error, error}
  end

  defp resolve_template(event_dir, transport, variant, format) do
    templates_dir = Path.join(event_dir, "templates")
    extension = extension_for(format)

    candidates =
      [
        variant && "#{transport}.#{variant}.#{extension}",
        "#{transport}.#{extension}",
        "default.#{extension}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Path.join(templates_dir, &1))

    Enum.find_value(candidates, :error, fn path ->
      if File.exists?(path), do: {:ok, path}, else: nil
    end)
  end

  defp extension_for(:html), do: "html.heex"
  defp extension_for(:text), do: "text.eex"

  defp render_template_content(template_content, assigns, _format) do
    # Preprocess HEEx-style attribute syntax to EEx syntax
    preprocessed = preprocess_heex_attributes(template_content)

    # Normalize assigns (convert struct to map if needed)
    normalized_assigns = if is_struct(assigns), do: Map.from_struct(assigns), else: assigns

    # Render with EEx
    rendered = EEx.eval_string(preprocessed, assigns: normalized_assigns)

    {:ok, rendered}
  rescue
    error ->
      {:error, error}
  end

  # Preprocessor to convert HEEx-style interpolation to EEx syntax
  # Handles:
  # 1. attr={@variable} → attr="<%= @variable %>"
  # 2. attr={"string #{@var}"} → attr="<%= "string #{@var}" %>"
  # 3. {@variable} → <%= @variable %>
  defp preprocess_heex_attributes(template) do
    template
    |> convert_attribute_syntax()
    |> convert_standalone_patterns()
  end

  # Convert standalone {@ and #{@ patterns, but NOT inside <%= ... %> tags
  defp convert_standalone_patterns(template) do
    parts = Regex.split(~r/<%=|%>/, template, include_captures: true)

    parts
    |> Enum.with_index()
    |> Enum.map(fn {part, idx} ->
      cond do
        # Keep <%= and %> delimiters as-is
        part in ["<%= ", " %>", "<%=", "%>"] ->
          part

        # If previous part was <%=, we're inside an EEx tag - don't convert
        idx > 0 and Enum.at(parts, idx - 1) in ["<%= ", "<%="] ->
          part

        # Otherwise, convert {@ and #{@ patterns
        true ->
          Regex.replace(~r/(?<![=])(#)?\{([^}]+)\}/, part, fn
            full_match, "", expr ->
              cond do
                String.starts_with?(expr, "@") ->
                  "<%= #{expr} %>"

                String.match?(expr, ~r/^[a-zA-Z_][a-zA-Z0-9_]*[.\(]/) ->
                  "<%= #{expr} %>"

                String.match?(expr, ~r/^[a-z_][a-z0-9_]*$/) ->
                  full_match

                true ->
                  full_match
              end

            full_match, "#", expr ->
              cond do
                String.starts_with?(expr, "@") or
                    String.match?(expr, ~r/^[a-zA-Z_][a-zA-Z0-9_]*[.\(]/) ->
                  "#<%= #{expr} %>"

                String.match?(expr, ~r/^[a-z_][a-z0-9_]*$/) ->
                  full_match

                true ->
                  full_match
              end
          end)
      end
    end)
    |> Enum.join("")
  end

  # Convert HEEx attribute syntax to EEx
  defp convert_attribute_syntax(template) do
    do_convert_attributes(template, "", :normal)
  end

  defp do_convert_attributes("", acc, _state), do: acc

  defp do_convert_attributes(template, acc, :normal) do
    case Regex.run(~r/(?<![#"])(\w+)=\{/, template, return: :index) do
      [{match_start, match_len}, {attr_start, attr_len}] ->
        <<before::binary-size(match_start), _match::binary-size(match_len), rest::binary>> =
          template

        <<_skip::binary-size(attr_start), attr_name::binary-size(attr_len), _::binary>> = template

        case find_matching_brace(rest) do
          {:ok, content, consumed_len} ->
            converted = ~s(#{attr_name}="<%= #{content} %>")
            <<_content_and_brace::binary-size(consumed_len + 1), remaining::binary>> = rest
            do_convert_attributes(remaining, acc <> before <> converted, :normal)

          :error ->
            kept_len = match_start + match_len
            <<kept::binary-size(kept_len), new_rest::binary>> = template
            do_convert_attributes(new_rest, acc <> kept, :normal)
        end

      nil ->
        acc <> template
    end
  end

  defp find_matching_brace(string), do: find_matching_brace(string, 0, 0, "", false)
  defp find_matching_brace("", _depth, _pos, _acc, _in_string), do: :error

  defp find_matching_brace(<<?"::utf8, rest::binary>>, depth, pos, acc, in_string) do
    find_matching_brace(rest, depth, pos + 1, acc <> <<?"::utf8>>, not in_string)
  end

  defp find_matching_brace(<<?{::utf8, rest::binary>>, depth, pos, acc, false = in_string) do
    find_matching_brace(rest, depth + 1, pos + 1, acc <> <<?{::utf8>>, in_string)
  end

  defp find_matching_brace(<<?}::utf8, _rest::binary>>, 0, pos, acc, false = _in_string) do
    {:ok, acc, pos}
  end

  defp find_matching_brace(<<?}::utf8, rest::binary>>, depth, pos, acc, false = in_string)
       when depth > 0 do
    find_matching_brace(rest, depth - 1, pos + 1, acc <> <<?}::utf8>>, in_string)
  end

  defp find_matching_brace(<<char::utf8, rest::binary>>, depth, pos, acc, in_string) do
    find_matching_brace(rest, depth, pos + 1, acc <> <<char::utf8>>, in_string)
  end
end
