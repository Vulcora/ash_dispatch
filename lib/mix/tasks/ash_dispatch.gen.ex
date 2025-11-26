defmodule Mix.Tasks.AshDispatch.Gen do
  @shortdoc "Generates missing AshDispatch templates and TypeScript types"

  @moduledoc """
  Generates missing files for AshDispatch events based on DSL definitions.

  This generator introspects all events defined in resources using `AshDispatch.Resource`
  and generates missing template files and TypeScript types.

  ## Usage

      mix ash_dispatch.gen              # Generate all missing files
      mix ash_dispatch.gen --check      # Exit with error if files missing (for CI)
      mix ash_dispatch.gen --dry-run    # Show what would be generated
      mix ash_dispatch.gen --verbose    # Show detailed output

  ## Integration with mix ash.codegen

  This task is automatically called when running `mix ash.codegen`:

      mix ash.codegen                   # Runs all extension codegens
      mix ash.codegen --check           # CI mode - fail if files missing
      mix ash.codegen --dry-run         # Preview all changes

  ## What Gets Generated

  ### Email Templates

  For each `:email` channel defined in your events:

  | File | When Generated |
  |------|----------------|
  | `email.html.heex` | Always for email channels |
  | `email.text.eex` | Always for email channels |
  | `email.{variant}.html.heex` | When channel has `variant: :xxx` |
  | `email.{variant}.text.eex` | When channel has `variant: :xxx` |

  Templates are placed in `{event_module_dir}/templates/`.

  ### TypeScript Types

  Generates `events.ts` in the same folder as your `ash_typescript` output:

  | Config | Output Path |
  |--------|-------------|
  | `output_file: "apps/frontend/src/lib/ash_rpc.ts"` | `apps/frontend/src/lib/ash-dispatch/events.ts` |

  Override with explicit config:

      config :ash_dispatch,
        typescript_events_output: "path/to/events.ts"

  ## Configuration

      # TypeScript output (derived from ash_typescript by default)
      config :ash_typescript,
        output_file: "apps/frontend/src/lib/ash_rpc.ts"

      # Or explicit override
      config :ash_dispatch,
        typescript_events_output: "custom/path/events.ts"

  See the [Code Generation guide](lib/documentation/topics/code-generation.md) for details.
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("compile")

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          check: :boolean,
          dry_run: :boolean,
          verbose: :boolean
        ],
        aliases: [v: :verbose]
      )

    otp_app = Mix.Project.config()[:app]

    # Introspect all events
    events = AshDispatch.Introspection.all_events(otp_app)

    if opts[:verbose] do
      Mix.shell().info("Found #{length(events)} events")
    end

    # Find all missing files
    missing = %{
      templates: AshDispatch.Introspection.all_missing_templates(otp_app),
      event_modules: AshDispatch.Introspection.missing_event_modules(otp_app),
      typescript: check_typescript_status(otp_app, events)
    }

    total_missing = count_missing(missing)

    # Handle --check flag
    if opts[:check] && total_missing > 0 do
      raise Ash.Error.Framework.PendingCodegen,
        diff: build_diff(missing),
        explain: true
    end

    # Handle --dry-run flag
    if opts[:dry_run] do
      print_dry_run(missing)
      {:ok, []}
    else
      if total_missing == 0 do
        Mix.shell().info("All AshDispatch files are up to date.")
      else
        # Generate missing files
        generate_templates(missing.templates)
        generate_event_modules(missing.event_modules, otp_app)
        generate_typescript(missing.typescript, events, otp_app)

        Mix.shell().info("\nGenerated #{total_missing} file(s)")
      end

      {:ok, []}
    end
  end

  # ============================================================================
  # Missing File Detection
  # ============================================================================

  defp check_typescript_status(otp_app, events) do
    output_path = typescript_events_output(otp_app)

    if output_path && length(events) > 0 do
      expected_content = generate_typescript_content(events)
      current_content = if File.exists?(output_path), do: File.read!(output_path), else: ""

      # Compare without timestamp line
      expected_without_ts = remove_timestamp(expected_content)
      current_without_ts = remove_timestamp(current_content)

      if expected_without_ts != current_without_ts do
        %{path: output_path, content: expected_content}
      else
        nil
      end
    else
      nil
    end
  end

  defp remove_timestamp(content) do
    Regex.replace(~r/\/\/ Generated at: .*\n/, content, "")
  end

  defp count_missing(missing) do
    length(missing.templates) +
      length(missing.event_modules) +
      if(missing.typescript, do: 1, else: 0)
  end

  defp build_diff(missing) do
    template_diff =
      Map.new(missing.templates, fn t ->
        {t.path, generate_template_content(t)}
      end)

    module_diff =
      Map.new(missing.event_modules, fn m ->
        {m.module_path, generate_event_module_content(m)}
      end)

    typescript_diff =
      if missing.typescript do
        %{missing.typescript.path => missing.typescript.content}
      else
        %{}
      end

    Map.merge(template_diff, module_diff) |> Map.merge(typescript_diff)
  end

  # ============================================================================
  # Dry Run Output
  # ============================================================================

  defp print_dry_run(missing) do
    if length(missing.templates) > 0 do
      Mix.shell().info("\n#{IO.ANSI.cyan()}Templates to generate:#{IO.ANSI.reset()}")

      Enum.each(missing.templates, fn t ->
        Mix.shell().info("  #{t.path}")
      end)
    end

    if length(missing.event_modules) > 0 do
      Mix.shell().info("\n#{IO.ANSI.cyan()}Event modules to generate:#{IO.ANSI.reset()}")

      Enum.each(missing.event_modules, fn m ->
        Mix.shell().info("  #{m.module_path}")
      end)
    end

    if missing.typescript do
      Mix.shell().info("\n#{IO.ANSI.cyan()}TypeScript types to generate:#{IO.ANSI.reset()}")
      Mix.shell().info("  #{missing.typescript.path}")
    end

    total = count_missing(missing)

    if total == 0 do
      Mix.shell().info("\nAll files are up to date.")
    else
      Mix.shell().info("\n#{total} file(s) would be generated.")
    end
  end

  # ============================================================================
  # Template Generation
  # ============================================================================

  defp generate_templates(templates) do
    Enum.each(templates, fn template ->
      dir = Path.dirname(template.path)
      File.mkdir_p!(dir)

      content = generate_template_content(template)
      File.write!(template.path, content)

      Mix.shell().info([:green, "* creating ", :reset, template.path])
    end)
  end

  defp generate_template_content(template) do
    case {template.transport, template.format} do
      {:email, :html} -> generate_email_html_stub(template)
      {:email, :text} -> generate_email_text_stub(template)
      {:sms, :text} -> generate_sms_text_stub(template)
      _ -> "<%# TODO: Implement template for #{template.transport} %>\n"
    end
  end

  defp generate_email_html_stub(template) do
    variant_info = if template.variant, do: " (variant: #{template.variant})", else: ""

    """
    <%# Template for: #{template.event_id} %>
    <%# Transport: email, Format: html#{variant_info} %>
    <%#
      Available assigns (from prepare_template_assigns/2):
      - @source_url - Link back to source resource
      - Add custom assigns in your event module
    %>

    <p style="margin: 0 0 20px 0; font-size: 16px; line-height: 1.6; color: #374151;">
      Hej<%= if assigns[:display_name], do: " <strong>\#{@display_name}</strong>", else: "" %>,
    </p>

    <p style="margin: 0 0 20px 0; font-size: 16px; line-height: 1.6; color: #374151;">
      TODO: Add your email content here.
    </p>

    <!-- Example: Details box -->
    <!--
    <div style="background-color: #f0f9ff; border-left: 4px solid #2563eb; padding: 20px; margin: 25px 0; border-radius: 4px;">
      <h2 style="margin: 0 0 15px 0; font-size: 18px; color: #1e40af;">
        Detaljer
      </h2>
      <table width="100%" cellpadding="0" cellspacing="0">
        <tr>
          <td style="padding: 5px 0; color: #6b7280; font-size: 14px;">ID:</td>
          <td style="padding: 5px 0; color: #374151; font-size: 14px; font-weight: 600; text-align: right;">
            {@id}
          </td>
        </tr>
      </table>
    </div>
    -->

    <!-- CTA Button -->
    <table width="100%" cellpadding="0" cellspacing="0" style="margin: 30px 0;">
      <tr>
        <td align="center">
          <a href={@source_url} style="display: inline-block; background: linear-gradient(135deg, #2563eb 0%, #1d4ed8 100%); color: #ffffff; padding: 16px 40px; text-decoration: none; border-radius: 6px; font-weight: 600; font-size: 16px;">
            Visa detaljer
          </a>
        </td>
      </tr>
    </table>
    """
  end

  defp generate_email_text_stub(template) do
    variant_info = if template.variant, do: " (variant: #{template.variant})", else: ""

    """
    <%# Template for: #{template.event_id} %>
    <%# Transport: email, Format: text#{variant_info} %>

    Hej<%= if assigns[:display_name], do: " \#{@display_name}", else: "" %>!

    TODO: Add your plain text email content here.

    Visa detaljer: <%= @source_url %>
    """
  end

  defp generate_sms_text_stub(template) do
    """
    <%# Template for: #{template.event_id} %>
    <%# Transport: sms %>

    TODO: Add your SMS content here (keep it short!)

    <%= @source_url %>
    """
  end

  # ============================================================================
  # Event Module Generation
  # ============================================================================

  defp generate_event_modules(modules, _otp_app) do
    Enum.each(modules, fn module_info ->
      dir = Path.dirname(module_info.module_path)
      File.mkdir_p!(dir)

      content = generate_event_module_content(module_info)
      File.write!(module_info.module_path, content)

      Mix.shell().info([:green, "* creating ", :reset, module_info.module_path])
    end)
  end

  defp generate_event_module_content(module_info) do
    event_info = module_info.event_info
    module_name = inspect(module_info.module_name)
    data_key = event_info[:data_key] || event_info[:name] || :record

    """
    defmodule #{module_name} do
      @moduledoc \"\"\"
      Event module for #{event_info.event_id}.

      Generated by `mix ash_dispatch.gen` - customize callbacks as needed.
      \"\"\"

      use AshDispatch.Event

      # Override callbacks to customize behavior:

      # @impl true
      # def prepare_template_assigns(context, channel) do
      #   # Add custom template variables
      #   %{
      #     id: context.data.#{data_key}.id,
      #     # Add more assigns as needed
      #   }
      # end

      # @impl true
      # def recipients(context, %{audience: :admin}) do
      #   # Custom admin recipients
      #   [%{email: "admin@example.com", name: "Admin"}]
      # end
      # def recipients(context, channel) do
      #   # Default recipient resolution
      #   super(context, channel)
      # end

      # @impl true
      # def should_send?(context, channel) do
      #   # Add custom gating logic
      #   true
      # end
    end
    """
  end

  # ============================================================================
  # TypeScript Generation
  # ============================================================================

  defp generate_typescript(nil, _events, _otp_app), do: :ok

  defp generate_typescript(typescript_info, _events, _otp_app) do
    dir = Path.dirname(typescript_info.path)
    File.mkdir_p!(dir)

    File.write!(typescript_info.path, typescript_info.content)

    Mix.shell().info([:green, "* creating ", :reset, typescript_info.path])
  end

  defp typescript_events_output(otp_app) do
    # Priority:
    # 1. Explicit ash_dispatch config
    # 2. Derive from ash_typescript output_file (same folder + ash-dispatch/events.ts)
    explicit_config =
      Application.get_env(:ash_dispatch, :typescript_events_output) ||
        Application.get_env(otp_app, :ash_dispatch)[:typescript_events_output]

    if explicit_config do
      explicit_config
    else
      derive_from_ash_typescript()
    end
  end

  defp derive_from_ash_typescript do
    # Get ash_typescript output_file and derive our path from it
    ash_ts_output = Application.get_env(:ash_typescript, :output_file)

    if ash_ts_output do
      # Same folder as ash_typescript output + ash-dispatch/events.ts
      # e.g., "apps/frontend/src/lib/ash_rpc.ts" -> "apps/frontend/src/lib/ash-dispatch/events.ts"
      base_dir = Path.dirname(ash_ts_output)
      Path.join([base_dir, "ash-dispatch", "events.ts"])
    else
      nil
    end
  end

  defp generate_typescript_content(events) do
    event_ids =
      events
      |> Enum.map(& &1.event_id)
      |> Enum.sort()

    event_id_union =
      if Enum.empty?(event_ids) do
        "never"
      else
        event_ids
        |> Enum.map(&~s("#{&1}"))
        |> Enum.join("\n  | ")
      end

    event_metadata =
      events
      |> Enum.sort_by(& &1.event_id)
      |> Enum.map(&format_event_metadata/1)
      |> Enum.join(",\n")

    """
    // Auto-generated by mix ash_dispatch.gen
    // Do not edit manually
    // Generated at: #{DateTime.utc_now() |> DateTime.to_iso8601()}

    /**
     * All dispatch event IDs in the application.
     */
    export type EventId =
      | #{event_id_union};

    /**
     * Event metadata for each event type.
     */
    export const EVENT_METADATA = {
    #{event_metadata}
    } as const;

    /**
     * Check if a string is a valid event ID.
     */
    export function isValidEventId(id: string): id is EventId {
      return id in EVENT_METADATA;
    }

    export type Transport = "email" | "in_app" | "sms" | "webhook" | "discord" | "slack";
    export type Audience = "user" | "admin" | "system";

    export type EventChannel = {
      transport: Transport;
      audience: Audience;
      variant?: string;
    };
    """
  end

  defp format_event_metadata(event) do
    channels_json =
      event.channels
      |> Enum.map(fn ch ->
        variant_str = if ch[:variant], do: ~s(, variant: "#{ch[:variant]}"), else: ""
        transport = ch[:transport] || "unknown"
        audience = ch[:audience] || "unknown"
        ~s({ transport: "#{transport}", audience: "#{audience}"#{variant_str} })
      end)
      |> Enum.join(", ")

    domain = event.domain || "unknown"

    ~s(  "#{event.event_id}": {\n    domain: "#{domain}",\n    channels: [#{channels_json}],\n  })
  end
end
