defmodule AshDispatch.TemplateResolver do
  alias AshDispatch.Config
  alias AshDispatch.Naming

  @moduledoc """
  Resolves and renders HEEx/EEx templates for events with fallback chain.

  Supports both development (file-based) and production (priv-based) templates.

  ## Layout System

  Templates can use layouts to share common structure (headers, footers, branding).

  **Layout location:** `priv/ash_dispatch/layouts/`

  **Layout naming:** `{transport}.{format}` e.g., `email.html.heex`, `email.text.eex`

  **Content injection:** Use `<%= @inner_content %>` in layouts where event content should appear.

  Example layout (`priv/ash_dispatch/layouts/email.html.heex`):

      <!DOCTYPE html>
      <html>
        <head><title><%= @subject %></title></head>
        <body>
          <header>Your Brand</header>
          <%= @inner_content %>
          <footer>Contact info</footer>
        </body>
      </html>

  ## Compilation Strategy

  **Development:** Templates are loaded from files for fast iteration.

  **Production:** Templates are auto-copied during `mix compile` by the
  `Mix.Tasks.Compile.AshDispatch` compiler. All templates (both convention-based
  and module-based) are discovered and copied to `priv/ash_dispatch/templates/`
  with a manifest for lookup.

  No manual template compilation needed - it happens automatically!

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

  require Logger

  @doc """
  Renders a template with the given options.

  ## Options

  * `:event_dir` - Optional in production. The directory of the event module (use `__DIR__`)
  * `:event_module` - Optional. The event module with compiled templates
  * `:event_id` - Optional. Event ID for convention-based path derivation
  * `:template_path` - Optional. Explicit template path override
  * `:otp_app` - Optional. OTP application name for convention-based paths
  * `:domain` - Optional. Domain name for convention-based paths (e.g., "requests")
  * `:resource_name` - Optional. Resource name for convention-based paths (e.g., "reseller_request")
  * `:format` - Required. Either `:html` or `:text`
  * `:transport` - Required. The transport type (e.g., `:email`)
  * `:variant` - Optional. A variant hint like "admin" or "user"
  * `:locale` - Optional. Locale for i18n template selection (e.g., "en", "sv")
  * `:assigns` - Required. Map of variables available in template as @variable

  ## Template Path Resolution

  Templates are resolved in this order:

  1. **Module-based:** If `:event_module` with `__compiled_templates__/0`, use compiled templates
  2. **Explicit path:** If `:event_dir` or `:template_path` provided, use that
  3. **Convention-based:** Derive from `:event_id`, `:otp_app`, `:domain`, and `:resource_name`
     - Event ID: "reseller_request.new_reseller_request"
     - Domain: "requests"
     - Resource: "reseller_request"
     - Convention: "lib/{otp_app}/{domain}/templates/{resource_name}/{event_name}"
     - Result: "lib/magasin/requests/templates/reseller_request/new_reseller_request"
     - Legacy (no resource_name): "lib/magasin/requests/templates/new_reseller_request"
  4. **Error:** `:template_not_found`

  ## Returns

  * `{:ok, rendered_string}` - Successfully rendered template
  * `{:error, :template_not_found}` - No matching template found
  * `{:error, reason}` - Rendering error
  """
  def render(opts) do
    event_module = Keyword.get(opts, :event_module)
    event_dir = Keyword.get(opts, :event_dir)
    template_path = Keyword.get(opts, :template_path)
    event_id = Keyword.get(opts, :event_id)
    otp_app = Keyword.get(opts, :otp_app)
    # Domain name for template path resolution
    domain = Keyword.get(opts, :domain)
    # Resource name for template path resolution
    resource_name = Keyword.get(opts, :resource_name)
    format = Keyword.fetch!(opts, :format)
    transport = Keyword.fetch!(opts, :transport)
    variant = Keyword.get(opts, :variant)
    locale = Keyword.get(opts, :locale)
    assigns = Keyword.fetch!(opts, :assigns)

    # Try priv templates first (production), fall back to files (development)
    # Note: Explicit paths are prioritized over automatic lookups
    cond do
      # 1. Event module with compiled templates (legacy, deprecated)
      event_module && function_exported?(event_module, :__compiled_templates__, 0) ->
        render_from_compiled(event_module, transport, variant, locale, format, assigns)

      # 2. File-based: Explicit template path (highest priority for user overrides)
      template_path ->
        # Explicit path: already points to template directory, don't add /templates
        render_from_files(
          template_path,
          transport,
          variant,
          locale,
          format,
          assigns,
          false,
          otp_app
        )

      # 3. File-based: Explicit event_dir with templates/ subdirectory
      event_dir ->
        # Module-based: event_dir is __DIR__, add /templates subdirectory
        render_from_files(event_dir, transport, variant, locale, format, assigns, true, otp_app)

      # 4. File-based: Derive event_dir from module source (development)
      event_module && derive_module_dir(event_module) ->
        render_from_files(
          derive_module_dir(event_module),
          transport,
          variant,
          locale,
          format,
          assigns,
          true,
          otp_app
        )

      # 5. Priv directory manifest (module-based events)
      event_module && otp_app && priv_manifest_exists?(otp_app) ->
        render_from_priv_manifest(
          {:module, event_module},
          otp_app,
          transport,
          variant,
          locale,
          format,
          assigns
        )

      # 5. Priv directory manifest (convention-based events)
      event_id && otp_app && priv_manifest_exists?(otp_app) ->
        render_from_priv_manifest(
          {:event_id, event_id},
          otp_app,
          transport,
          variant,
          locale,
          format,
          assigns
        )

      # 6. File-based: Convention-based path (development fallback)
      event_id && otp_app ->
        # Convention-based: path already points to template directory, don't add /templates
        convention_path = derive_template_path(event_id, otp_app, domain, resource_name)

        render_from_files(
          convention_path,
          transport,
          variant,
          locale,
          format,
          assigns,
          false,
          otp_app
        )

      true ->
        maybe_warn_missing_template_config(event_module, event_id, otp_app)
        {:error, :template_not_found}
    end
  end

  # Warn about missing compile_templates config when running in a release
  # This helps users understand why templates aren't loading in production
  defp maybe_warn_missing_template_config(event_module, event_id, otp_app) do
    # Only warn in release mode (when lib/ sources aren't available)
    if release_mode?() do
      identifier =
        cond do
          event_module -> "module: #{inspect(event_module)}"
          event_id -> "event_id: #{event_id}"
          true -> "unknown event"
        end

      has_manifest =
        case otp_app do
          nil -> false
          app -> priv_manifest_exists?(app)
        end

      unless has_manifest do
        Logger.warning("""
        [AshDispatch] Template not found for #{identifier}

        This is likely because `compile_templates: true` is not set in config/prod.exs.

        In production releases, templates must be compiled to priv/ during build because
        lib/ source files are not included in releases.

        Add to config/prod.exs:

            config :ash_dispatch,
              compile_templates: true

        Then rebuild your release. See: https://hexdocs.pm/ash_dispatch/code-generation.html
        """)
      end
    end
  end

  # Detect if running in a release (Mix module is not available)
  defp release_mode? do
    not function_exported?(Mix, :env, 0)
  end

  # Check if priv manifest exists for the given OTP app
  defp priv_manifest_exists?(otp_app) do
    case manifest_path(otp_app) do
      {:ok, path} -> File.exists?(path)
      {:error, _} -> false
    end
  end

  # Derive directory from module's source file (for development mode)
  # Returns nil if source info is not available (e.g., in releases)
  defp derive_module_dir(event_module) do
    case event_module.__info__(:compile)[:source] do
      nil -> nil
      source -> source |> to_string() |> Path.dirname()
    end
  rescue
    _ -> nil
  end

  # Get manifest path for the given OTP app
  defp manifest_path(otp_app) do
    case :code.priv_dir(otp_app) do
      {:error, _} = error ->
        error

      priv_dir ->
        path =
          priv_dir
          |> to_string()
          |> Path.join("ash_dispatch/manifest.json")

        {:ok, path}
    end
  end

  # Render from compiled templates (production)
  defp render_from_compiled(event_module, transport, variant, locale, format, assigns) do
    templates = event_module.__compiled_templates__()
    candidates = build_template_candidates(transport, variant, locale, format)

    case Enum.find_value(candidates, fn
           nil -> nil
           filename -> Map.get(templates, filename)
         end) do
      nil ->
        {:error, :template_not_found}

      template_content ->
        render_template_content(template_content, assigns, format, locale: locale)
    end
  end

  # Render from priv directory manifest
  defp render_from_priv_manifest(lookup_key, otp_app, transport, variant, locale, format, assigns) do
    candidates = build_template_candidates(transport, variant, locale, format)

    with {:ok, manifest} <- load_manifest(otp_app),
         manifest_key <- format_manifest_key(lookup_key),
         template_map when not is_nil(template_map) <- Map.get(manifest, manifest_key),
         {:ok, dest_filename} <- find_template_in_map(template_map, candidates),
         {:ok, template_content} <- read_template_from_priv(otp_app, dest_filename) do
      render_template_content(template_content, assigns, format,
        otp_app: otp_app,
        transport: transport,
        locale: locale
      )
    else
      _ -> {:error, :template_not_found}
    end
  end

  # Load and parse the manifest for the given OTP app
  defp load_manifest(otp_app) do
    with {:ok, path} <- manifest_path(otp_app),
         {:ok, content} <- File.read(path) do
      Jason.decode(content)
    else
      {:error, _} -> {:error, :manifest_not_found}
    end
  end

  # Format lookup key to manifest key format
  defp format_manifest_key({:event_id, event_id}), do: "event_id:#{event_id}"
  defp format_manifest_key({:module, module}), do: "module:#{inspect(module)}"

  # Find first matching template filename in template map
  defp find_template_in_map(template_map, candidates) do
    case Enum.find_value(candidates, fn
           nil -> nil
           filename -> Map.get(template_map, filename)
         end) do
      nil -> {:error, :template_not_found}
      dest_filename -> {:ok, dest_filename}
    end
  end

  # Read template content from priv directory of the given OTP app
  defp read_template_from_priv(otp_app, dest_filename) do
    case :code.priv_dir(otp_app) do
      {:error, _} ->
        {:error, :template_not_found}

      priv_dir ->
        priv_templates_dir =
          priv_dir
          |> to_string()
          |> Path.join("ash_dispatch/templates")

        template_path = Path.join(priv_templates_dir, dest_filename)

        case File.read(template_path) do
          {:ok, content} -> {:ok, content}
          {:error, _} -> {:error, :template_not_found}
        end
    end
  end

  # Render from files (development)
  defp render_from_files(
         event_dir,
         transport,
         variant,
         locale,
         format,
         assigns,
         add_templates_subdir,
         otp_app
       ) do
    template_path =
      resolve_template(event_dir, transport, variant, locale, format, add_templates_subdir)

    case template_path do
      {:ok, path} ->
        template_content = File.read!(path)

        render_template_content(template_content, assigns, format,
          otp_app: otp_app,
          transport: transport,
          locale: locale
        )

      :error ->
        {:error, :template_not_found}
    end
  rescue
    error ->
      {:error, error}
  end

  defp resolve_template(event_dir, transport, variant, locale, format, add_templates_subdir) do
    # For module-based events, add /templates subdirectory
    # For convention-based paths, the path already points to the template directory
    templates_dir =
      if add_templates_subdir do
        Path.join(event_dir, "templates")
      else
        event_dir
      end

    candidates =
      build_template_candidates(transport, variant, locale, format)
      |> Enum.map(&Path.join(templates_dir, &1))

    Enum.find_value(candidates, :error, fn path ->
      if File.exists?(path), do: {:ok, path}, else: nil
    end)
  end

  # Build template candidate filenames with locale support
  # Fallback chain: variant+locale → variant → locale → base → default+locale → default
  defp build_template_candidates(transport, variant, locale, format) do
    extension = extension_for(format)

    [
      # Most specific: variant + locale
      variant && locale && "#{transport}.#{variant}.#{locale}.#{extension}",
      # Variant only (default locale)
      variant && "#{transport}.#{variant}.#{extension}",
      # Locale only
      locale && "#{transport}.#{locale}.#{extension}",
      # Base template
      "#{transport}.#{extension}",
      # Default with locale
      locale && "default.#{locale}.#{extension}",
      # Ultimate fallback
      "default.#{extension}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # Format to file extension mapping
  # Configure custom formats via:
  #   config :ash_dispatch, format_extensions: %{markdown: "md.eex"}
  #
  # Default formats:
  #   :html -> "html.heex" (HTML emails with HEEx syntax)
  #   :text -> "text.eex"  (Plain text emails/SMS)
  #
  # Future transports can add formats like:
  #   :markdown -> "md.eex" (Discord/Slack messages)
  #   :json -> "json.eex"   (Webhook payloads)
  defp extension_for(format) do
    custom_extensions = Config.format_extensions()

    defaults = %{
      html: "html.heex",
      text: "text.eex"
    }

    Map.get(custom_extensions, format) || Map.get(defaults, format) ||
      raise "Unknown format #{inspect(format)}. Add it to config :ash_dispatch, format_extensions: %{#{format}: \"extension.eex\"}"
  end

  defp render_template_content(template_content, assigns, format, opts) do
    # Preprocess HEEx-style attribute syntax to EEx syntax. For :html
    # format the preprocessor wraps `{@var}` expansions in
    # `AshDispatch.SafeRender.escape/1` so user-controlled assigns can't
    # inject markup into the rendered output — matching Phoenix HEEx
    # auto-escape semantics. Other formats (text, etc.) are emitted as
    # plain `<%= @var %>` and rely on the format's own quoting rules.
    preprocessed = preprocess_heex_attributes(template_content, format)

    # Normalize assigns (convert struct to map if needed)
    normalized_assigns = if is_struct(assigns), do: Map.from_struct(assigns), else: assigns

    # Set Gettext locale before rendering so dgettext/t() calls in templates resolve correctly.
    # This enables single-template-per-event i18n: templates use Gettext instead of per-locale files.
    set_render_locale(Keyword.get(opts, :locale))

    # Render with EEx
    rendered = EEx.eval_string(preprocessed, assigns: normalized_assigns)

    # Check if we should wrap in layout
    otp_app = Keyword.get(opts, :otp_app)
    transport = Keyword.get(opts, :transport)
    layout = Keyword.get(opts, :layout)

    if otp_app && transport do
      wrap_in_layout(rendered, otp_app, transport, format, normalized_assigns, layout)
    else
      {:ok, rendered}
    end
  rescue
    error ->
      {:error, error}
  end

  # Set Gettext locale for template rendering.
  # Enables dgettext()/t() calls in email templates to resolve per-recipient locale.
  # Falls back gracefully if no gettext_backend configured or locale is nil.
  defp set_render_locale(nil), do: :ok

  defp set_render_locale(locale) when is_binary(locale) do
    case AshDispatch.Config.gettext_backend() do
      nil -> :ok
      backend -> apply(Gettext, :put_locale, [backend, locale])
    end
  rescue
    _ -> :ok
  end

  defp set_render_locale(locale) when is_atom(locale) and not is_nil(locale),
    do: set_render_locale(to_string(locale))

  defp set_render_locale(_), do: :ok

  # Wrap rendered content in layout if layout exists
  # layout_subdir is an optional subdirectory (e.g., "urgent" -> layouts/urgent/email.html.heex)
  defp wrap_in_layout(content, otp_app, transport, format, assigns, layout_subdir) do
    case load_layout(otp_app, transport, format, layout_subdir) do
      {:ok, layout_content} ->
        # Add rendered content to assigns as @inner_content
        # Also ensure subject has a default to avoid template errors
        layout_assigns =
          assigns
          |> Map.put(:inner_content, content)
          |> Map.put_new(:subject, "")

        # Preprocess and render layout (locale already set by render_template_content)
        preprocessed = preprocess_heex_attributes(layout_content, format)
        rendered = EEx.eval_string(preprocessed, assigns: layout_assigns)

        {:ok, rendered}

      {:error, :layout_not_found} ->
        # No layout, return content as-is
        {:ok, content}
    end
  rescue
    error ->
      {:error, error}
  end

  # Load layout from priv/ash_dispatch/layouts/
  # layout_subdir allows per-channel overrides (e.g., "urgent" -> layouts/urgent/email.html.heex)
  defp load_layout(otp_app, transport, format, layout_subdir)

  defp load_layout(otp_app, transport, format, layout_subdir) do
    extension = extension_for(format)
    layout_filename = "#{transport}.#{extension}"

    case :code.priv_dir(otp_app) do
      {:error, _} ->
        {:error, :layout_not_found}

      priv_dir ->
        base_path = priv_dir |> to_string() |> Path.join("ash_dispatch/layouts")

        # If layout_subdir specified, try that first, then fall back to default
        layout_paths =
          if layout_subdir do
            [
              Path.join([base_path, layout_subdir, layout_filename]),
              Path.join(base_path, layout_filename)
            ]
          else
            [Path.join(base_path, layout_filename)]
          end

        # Try each path in order
        Enum.find_value(layout_paths, {:error, :layout_not_found}, fn path ->
          case File.read(path) do
            {:ok, content} -> {:ok, content}
            {:error, _} -> nil
          end
        end)
    end
  end

  # Preprocessor to convert HEEx-style interpolation to EEx syntax.
  # For `format == :html`, `{@var}` expansions are wrapped in
  # `AshDispatch.SafeRender.escape/1` so they auto-escape (matching
  # Phoenix HEEx). Non-HTML formats emit `<%= … %>` unchanged.
  #
  # Handles:
  # 1. attr={@variable} → attr="<%= AshDispatch.SafeRender.escape(@variable) %>" (html)
  #                     → attr="<%= @variable %>"                                (text)
  # 2. attr={"string #{@var}"} → attr="<%= "string #{@var}" %>" (unchanged — full Elixir)
  # 3. {@variable} → <%= AshDispatch.SafeRender.escape(@variable) %>  (html)
  #               → <%= @variable %>                                  (text)
  defp preprocess_heex_attributes(template, format) do
    template
    |> convert_attribute_syntax()
    |> convert_standalone_patterns(format)
  end

  # Elixir keywords/macros that should be converted when used in HEEx {} syntax
  @elixir_keywords ~w(if unless case cond for with)

  # Convert standalone {@ and #{@ patterns, but NOT inside <%= ... %> tags
  defp convert_standalone_patterns(template, format) do
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
          convert_heex_expressions(part, format)
      end
    end)
    |> Enum.join("")
  end

  # Convert HEEx curly-brace expressions to EEx <%= %> syntax
  # Handles nested braces correctly by using a stateful parser
  defp convert_heex_expressions(text, format) do
    do_convert_heex_expressions(text, "", format)
  end

  defp do_convert_heex_expressions("", acc, _format), do: acc

  defp do_convert_heex_expressions(<<?\#, ?\{, rest::binary>>, acc, format) do
    # String interpolation - skip it
    do_convert_heex_expressions(rest, acc <> "\#{", format)
  end

  defp do_convert_heex_expressions(<<?{::utf8, rest::binary>>, acc, format) do
    # Found opening brace - try to extract complete expression
    case extract_balanced_expression(rest, 0, "") do
      {:ok, expr, remaining} ->
        if should_convert_expression?(expr) do
          rendered = render_expression(expr, format)
          do_convert_heex_expressions(remaining, acc <> rendered, format)
        else
          do_convert_heex_expressions(remaining, acc <> "{" <> expr <> "}", format)
        end

      :error ->
        # No matching brace, keep as-is
        do_convert_heex_expressions(rest, acc <> "{", format)
    end
  end

  defp do_convert_heex_expressions(<<char::utf8, rest::binary>>, acc, format) do
    do_convert_heex_expressions(rest, acc <> <<char::utf8>>, format)
  end

  # Wrap the expansion in SafeRender.escape/1 for HTML formats so plain
  # `{@var}` auto-escapes. For non-HTML formats emit plain `<%= … %>`.
  # Already wrapped in an explicit `AshDispatch.SafeRender.raw(…)` call?
  # Strip the marker and skip the escape — matches Phoenix HEEx's
  # `Phoenix.HTML.raw/1` opt-out for trusted markup.
  defp render_expression(expr, :html) do
    trimmed = String.trim(expr)

    case strip_raw_call(trimmed) do
      {:ok, inner} ->
        "<%= " <> inner <> " %>"

      :no ->
        "<%= AshDispatch.SafeRender.escape(" <> trimmed <> ") %>"
    end
  end

  defp render_expression(expr, _format), do: "<%= " <> expr <> " %>"

  # Match `AshDispatch.SafeRender.raw(EXPR)` or `raw(EXPR)` exactly.
  defp strip_raw_call(expr) do
    cond do
      String.starts_with?(expr, "AshDispatch.SafeRender.raw(") and String.ends_with?(expr, ")") ->
        {:ok, String.slice(expr, String.length("AshDispatch.SafeRender.raw(") .. -2//1)}

      String.starts_with?(expr, "raw(") and String.ends_with?(expr, ")") ->
        {:ok, String.slice(expr, String.length("raw(") .. -2//1)}

      true ->
        :no
    end
  end

  # Extract a balanced expression handling nested braces and strings
  defp extract_balanced_expression("", _depth, _acc), do: :error

  defp extract_balanced_expression(<<?}::utf8, rest::binary>>, 0, acc) do
    {:ok, acc, rest}
  end

  defp extract_balanced_expression(<<?}::utf8, rest::binary>>, depth, acc) when depth > 0 do
    extract_balanced_expression(rest, depth - 1, acc <> "}")
  end

  defp extract_balanced_expression(<<?{::utf8, rest::binary>>, depth, acc) do
    extract_balanced_expression(rest, depth + 1, acc <> "{")
  end

  defp extract_balanced_expression(<<?"::utf8, rest::binary>>, depth, acc) do
    # Inside string - extract until closing quote (handling escapes)
    case extract_string(rest, <<?"::utf8>>) do
      {:ok, str_content, remaining} ->
        extract_balanced_expression(remaining, depth, acc <> str_content)

      :error ->
        :error
    end
  end

  defp extract_balanced_expression(<<char::utf8, rest::binary>>, depth, acc) do
    extract_balanced_expression(rest, depth, acc <> <<char::utf8>>)
  end

  # Extract a string literal handling escape sequences
  defp extract_string("", _acc), do: :error

  defp extract_string(<<"\\\""::utf8, rest::binary>>, acc) do
    extract_string(rest, acc <> "\\\"")
  end

  defp extract_string(<<?"::utf8, rest::binary>>, acc) do
    {:ok, acc <> "\"", rest}
  end

  defp extract_string(<<char::utf8, rest::binary>>, acc) do
    extract_string(rest, acc <> <<char::utf8>>)
  end

  # Determine if an expression should be converted to <%= %> syntax
  defp should_convert_expression?(expr) do
    trimmed = String.trim(expr)

    cond do
      # @variable expressions
      String.starts_with?(trimmed, "@") ->
        true

      # Elixir keywords/macros (if, unless, case, cond, for, with)
      starts_with_elixir_keyword?(trimmed) ->
        true

      # Function calls like Module.function() or function()
      String.match?(trimmed, ~r/^[a-zA-Z_][a-zA-Z0-9_]*[.\(]/) ->
        true

      # assigns[:key] pattern
      String.starts_with?(trimmed, "assigns[") ->
        true

      # Single lowercase identifier without parens - likely a CSS class or similar
      String.match?(trimmed, ~r/^[a-z_][a-z0-9_]*$/) ->
        false

      true ->
        false
    end
  end

  defp starts_with_elixir_keyword?(expr) do
    Enum.any?(@elixir_keywords, fn keyword ->
      String.starts_with?(expr, keyword <> " ") or String.starts_with?(expr, keyword <> "(")
    end)
  end

  # Convert HEEx attribute syntax to EEx
  defp convert_attribute_syntax(template) do
    do_convert_attributes(template, "", :normal)
  end

  defp do_convert_attributes("", acc, _state), do: acc

  defp do_convert_attributes(template, acc, :normal) do
    case Regex.run(~r/(?<![#"])(\w+)=\{/, template, return: :index) do
      [{match_start, match_len}, {attr_start, attr_len}] ->
        <<before::binary-size(^match_start), _match::binary-size(^match_len), rest::binary>> =
          template

        <<_skip::binary-size(^attr_start), attr_name::binary-size(^attr_len), _::binary>> = template

        case find_matching_brace(rest) do
          {:ok, content, consumed_len} ->
            converted = ~s(#{attr_name}="<%= #{content} %>")
            <<_content_and_brace::binary-size(^consumed_len + 1), remaining::binary>> = rest
            do_convert_attributes(remaining, acc <> before <> converted, :normal)

          :error ->
            kept_len = match_start + match_len
            <<kept::binary-size(^kept_len), new_rest::binary>> = template
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

  @doc """
  Resolves the template directory for an event.

  This is the **single source of truth** for template path resolution.
  Used by both the code generator and the runtime renderer.

  ## Resolution Order

  1. **Explicit module**: If event has `module:` option, use module-based path
  2. **Derived module**: Use `{App}.{Domain}.Events.{EventName}.Event` path

  Events are expected to have modules (either explicit or generated via `mix ash_dispatch.gen`).
  Templates live in `{module_dir}/templates/`.

  ## Parameters

  - `event_info` - Map with `:domain`, `:name`, and optionally `:module`
  - `otp_app` - The OTP application name

  ## Examples

      resolve_template_directory(%{domain: :accounts, name: :email_confirmation}, :magasin)
      # => "lib/magasin/accounts/events/email_confirmation/templates"

      resolve_template_directory(%{domain: :orders, name: :created}, :magasin)
      # => "lib/magasin/orders/events/created/templates"
  """
  @spec resolve_template_directory(map(), atom()) :: String.t()
  def resolve_template_directory(event_info, otp_app) do
    # 1. Explicit module takes priority
    case Map.get(event_info, :module) do
      module when is_atom(module) and not is_nil(module) ->
        module_path_from_module(module)

      nil ->
        # 2. Use derived module path
        # Events should have modules - either explicit or generated via codegen
        derived_module = derive_event_module(event_info, otp_app)
        module_path_from_module(derived_module)
    end
  end

  @doc """
  Derives the expected event module name from event info.

  Delegates to `AshDispatch.Naming.event_module/3` which is the single source
  of truth for module name derivation.

  ## Examples

      derive_event_module(%{domain: :accounts, name: :email_confirmation, resource: Magasin.Accounts.User}, :magasin)
      # => Magasin.Accounts.Events.EmailConfirmation.Event
  """
  @spec derive_event_module(map(), atom()) :: module()
  def derive_event_module(event_info, otp_app) do
    # If resource is available, use Naming.event_module for consistency
    # Otherwise fall back to otp_app-based derivation for backward compatibility
    case event_info[:resource] do
      resource when is_atom(resource) and not is_nil(resource) ->
        domain = event_info[:domain] || Naming.domain_name(resource)
        Naming.event_module(resource, domain, event_info[:name])

      nil ->
        # Fallback: derive from otp_app (for legacy/test cases)
        app_module = otp_app |> to_string() |> Macro.camelize()
        domain_module = event_info[:domain] |> to_string() |> Macro.camelize()
        event_module = event_info[:name] |> to_string() |> Macro.camelize()

        Module.concat([app_module, domain_module, "Events", event_module, "Event"])
    end
  end

  # Derives template path from module name
  # Delegates to Naming.template_directory/1 for consistent path derivation
  # Module: Magasin.Accounts.Events.PasswordReset.Event
  # Path: lib/magasin/accounts/events/password_reset/templates
  defp module_path_from_module(module) do
    Naming.template_directory(module)
  end

  @doc """
  Derives template path from event_id.

  Parses the event_id to extract domain and event name, then uses
  `resolve_template_directory/2` for the actual path resolution.

  ## Parameters

  - `event_id` - Event ID string (e.g., "orders.created", "user.email_confirmation")
  - `otp_app` - The OTP application name
  - `domain` - Optional domain override (uses first part of event_id if not provided)

  ## Examples

      derive_template_path("orders.created", :magasin)
      # => "lib/magasin/orders/events/created/templates"

      derive_template_path("user.email_confirmation", :magasin, "accounts")
      # => "lib/magasin/accounts/events/email_confirmation/templates"
  """
  def derive_template_path(event_id, otp_app, domain \\ nil, _resource_name \\ nil)
      when is_binary(event_id) and is_atom(otp_app) do
    case String.split(event_id, ".", parts: 2) do
      [resource_or_domain, event_name] ->
        domain_atom =
          if domain,
            do: String.to_atom(to_string(domain)),
            else: String.to_atom(resource_or_domain)

        resolve_template_directory(
          %{domain: domain_atom, name: String.to_atom(event_name)},
          otp_app
        )

      [single_part] ->
        domain_atom =
          if domain,
            do: String.to_atom(to_string(domain)),
            else: :dispatch

        resolve_template_directory(
          %{domain: domain_atom, name: String.to_atom(single_part)},
          otp_app
        )
    end
  end
end
