defmodule AshDispatch.TemplateResolver do
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

  require EEx

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
    assigns = Keyword.fetch!(opts, :assigns)

    # Try priv templates first (production), fall back to files (development)
    # Note: Explicit paths are prioritized over automatic lookups
    cond do
      # 1. Event module with compiled templates (legacy, deprecated)
      event_module && function_exported?(event_module, :__compiled_templates__, 0) ->
        render_from_compiled(event_module, transport, variant, format, assigns)

      # 2. File-based: Explicit template path (highest priority for user overrides)
      template_path ->
        # Explicit path: already points to template directory, don't add /templates
        render_from_files(template_path, transport, variant, format, assigns, false, otp_app)

      # 3. File-based: Module with templates/ subdirectory
      event_dir ->
        # Module-based: event_dir is __DIR__, add /templates subdirectory
        render_from_files(event_dir, transport, variant, format, assigns, true, otp_app)

      # 4. Priv directory manifest (module-based events)
      event_module && otp_app && priv_manifest_exists?(otp_app) ->
        render_from_priv_manifest(
          {:module, event_module},
          otp_app,
          transport,
          variant,
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
          format,
          assigns
        )

      # 6. File-based: Convention-based path (development fallback)
      event_id && otp_app ->
        # Convention-based: path already points to template directory, don't add /templates
        convention_path = derive_template_path(event_id, otp_app, domain, resource_name)
        render_from_files(convention_path, transport, variant, format, assigns, false, otp_app)

      true ->
        {:error, :template_not_found}
    end
  end

  # Check if priv manifest exists for the given OTP app
  defp priv_manifest_exists?(otp_app) do
    case manifest_path(otp_app) do
      {:ok, path} -> File.exists?(path)
      {:error, _} -> false
    end
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

  # Render from priv directory manifest
  defp render_from_priv_manifest(lookup_key, otp_app, transport, variant, format, assigns) do
    extension = extension_for(format)

    candidates = [
      variant && "#{transport}.#{variant}.#{extension}",
      "#{transport}.#{extension}",
      "default.#{extension}"
    ]

    with {:ok, manifest} <- load_manifest(otp_app),
         manifest_key <- format_manifest_key(lookup_key),
         template_map when not is_nil(template_map) <- Map.get(manifest, manifest_key),
         {:ok, dest_filename} <- find_template_in_map(template_map, candidates),
         {:ok, template_content} <- read_template_from_priv(otp_app, dest_filename) do
      render_template_content(template_content, assigns, format,
        otp_app: otp_app,
        transport: transport
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
         format,
         assigns,
         add_templates_subdir,
         otp_app
       ) do
    template_path = resolve_template(event_dir, transport, variant, format, add_templates_subdir)

    case template_path do
      {:ok, path} ->
        template_content = File.read!(path)

        render_template_content(template_content, assigns, format,
          otp_app: otp_app,
          transport: transport
        )

      :error ->
        {:error, :template_not_found}
    end
  rescue
    error ->
      {:error, error}
  end

  defp resolve_template(event_dir, transport, variant, format, add_templates_subdir) do
    # For module-based events, add /templates subdirectory
    # For convention-based paths, the path already points to the template directory
    templates_dir =
      if add_templates_subdir do
        Path.join(event_dir, "templates")
      else
        event_dir
      end

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
    custom_extensions = Application.get_env(:ash_dispatch, :format_extensions, %{})

    defaults = %{
      html: "html.heex",
      text: "text.eex"
    }

    Map.get(custom_extensions, format) || Map.get(defaults, format) ||
      raise "Unknown format #{inspect(format)}. Add it to config :ash_dispatch, format_extensions: %{#{format}: \"extension.eex\"}"
  end

  defp render_template_content(template_content, assigns, format, opts \\ []) do
    # Preprocess HEEx-style attribute syntax to EEx syntax
    preprocessed = preprocess_heex_attributes(template_content)

    # Normalize assigns (convert struct to map if needed)
    normalized_assigns = if is_struct(assigns), do: Map.from_struct(assigns), else: assigns

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

        # Preprocess and render layout
        preprocessed = preprocess_heex_attributes(layout_content)
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

  @doc """
  Derives template path from event_id using convention.

  If `domain` and `resource_name` are provided, uses them for the path.
  Otherwise extracts from event_id (legacy support).

  ## New Structure (resource.event format)

  Templates are now organized by domain/resource/event to prevent collisions:

      # With explicit domain and resource_name (current format)
      derive_template_path("reseller_request.new_reseller_request", :magasin, "requests", "reseller_request")
      # => "lib/magasin/requests/templates/reseller_request/new_reseller_request"

  ## Legacy Structure (domain.event format - deprecated)

  For backwards compatibility, falls back to domain/event structure if no resource_name:

      # Without resource_name (legacy)
      derive_template_path("requests.new_reseller_request", :magasin, "requests", nil)
      # => "lib/magasin/requests/templates/new_reseller_request"

  ## Examples

      # Current format (prevents collisions)
      derive_template_path("reseller_request.created", :magasin, "requests", "reseller_request")
      # => "lib/magasin/requests/templates/reseller_request/created"

      derive_template_path("partner_request.created", :magasin, "requests", "partner_request")
      # => "lib/magasin/requests/templates/partner_request/created"

      # Legacy format (can cause collisions)
      derive_template_path("requests.created", :magasin, "requests", nil)
      # => "lib/magasin/requests/templates/created"
  """
  def derive_template_path(event_id, otp_app, domain \\ nil, resource_name \\ nil)
      when is_binary(event_id) and is_atom(otp_app) do
    case String.split(event_id, ".", parts: 2) do
      [resource_or_domain, event_name] ->
        # Extract domain and resource name
        domain_name = domain || resource_or_domain
        res_name = resource_name || resource_or_domain

        # If we have a resource_name, use new structure: lib/{app}/{domain}/templates/{resource}/{event}
        # Otherwise use legacy structure: lib/{app}/{domain}/templates/{event}
        if resource_name do
          Path.join(["lib", to_string(otp_app), domain_name, "templates", res_name, event_name])
        else
          # Legacy path for backwards compatibility
          Path.join(["lib", to_string(otp_app), domain_name, "templates", event_name])
        end

      [single_part] ->
        # Fallback if no domain separator (shouldn't happen with auto-generated IDs)
        domain_name = domain || "dispatch"

        if resource_name do
          Path.join([
            "lib",
            to_string(otp_app),
            domain_name,
            "templates",
            resource_name,
            single_part
          ])
        else
          Path.join(["lib", to_string(otp_app), domain_name, "templates", single_part])
        end
    end
  end
end
