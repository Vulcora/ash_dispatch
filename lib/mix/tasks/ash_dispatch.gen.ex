defmodule Mix.Tasks.AshDispatch.Gen do
  @shortdoc "Generates missing AshDispatch templates, TypeScript types, and SDK"

  @moduledoc """
  Generates missing files for AshDispatch events based on DSL definitions.

  This generator introspects all events and counters defined in resources using
  `AshDispatch.Resource` and generates missing template files, TypeScript types,
  and the complete SDK.

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

  ### TypeScript SDK

  Generates a complete SDK in `lib/ash-dispatch/` (next to your ash_typescript output):

  | File | Description |
  |------|-------------|
  | `types.ts` | Counter types, defaults, metadata, and accessors |
  | `events.ts` | Event ID types and metadata |
  | `store.ts` | Zustand store for counter state |
  | `channel.ts` | Phoenix channel utilities |
  | `index.ts` | Re-exports all SDK modules |
  | `hooks/use-channel.ts` | Channel connection hook |
  | `hooks/use-counter.ts` | Single counter access hook |
  | `hooks/use-notifications.ts` | Notification actions hook |

  ## Configuration

  TypeScript SDK generation requires `ash_typescript` to be configured:

      # TypeScript output path (required for SDK generation)
      config :ash_typescript,
        output_file: "apps/frontend/src/lib/ash_rpc.ts"

      # SDK will be generated to: apps/frontend/src/lib/ash-dispatch/

  Without this configuration, only templates and event modules will be generated.
  You can also explicitly configure the SDK output path:

      config :ash_dispatch,
        sdk_output_path: "apps/frontend/src/lib/ash-dispatch"

  See the [Code Generation guide](lib/documentation/topics/code-generation.md) for details.
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    # Guard: prevent running from ash_dispatch library itself
    if Mix.Project.config()[:app] == :ash_dispatch do
      Mix.shell().error("This task cannot be run from the ash_dispatch library itself.")
      Mix.shell().info("Run this task from your consuming application instead.")
      exit({:shutdown, 1})
    end

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
    sdk_enabled = typescript_sdk_enabled?(otp_app)

    # Introspect all events and counters
    events = AshDispatch.Introspection.all_events(otp_app)
    counters = discover_counters(otp_app)

    # Warn if no events or counters found (common misconfiguration)
    warn_if_no_dispatch_resources(otp_app, events, counters)

    if opts[:verbose] do
      Mix.shell().info("Found #{length(events)} events, #{length(counters)} counters")

      if sdk_enabled do
        Mix.shell().info("TypeScript SDK output: #{sdk_base_path(otp_app)}")
      else
        Mix.shell().info("TypeScript SDK generation disabled (ash_typescript not configured)")
      end
    end

    # Find all missing files (SDK checks return nil/[] when disabled)
    missing = %{
      templates: AshDispatch.Introspection.all_missing_templates(otp_app),
      event_modules: AshDispatch.Introspection.missing_event_modules(otp_app),
      typescript_events:
        if(sdk_enabled, do: check_typescript_events_status(otp_app, events), else: nil),
      typescript_types:
        if(sdk_enabled, do: check_typescript_types_status(otp_app, counters), else: nil),
      sdk_files: if(sdk_enabled, do: check_sdk_status(otp_app), else: [])
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
      print_dry_run(missing, counters, sdk_enabled)
      {:ok, []}
    else
      generated_count = 0

      # Generate missing files
      generated_count = generated_count + generate_templates(missing.templates)
      generated_count = generated_count + generate_event_modules(missing.event_modules, otp_app)
      generated_count = generated_count + generate_typescript_events(missing.typescript_events)

      generated_count =
        generated_count + generate_typescript_types(missing.typescript_types, counters)

      generated_count = generated_count + generate_sdk_files(missing.sdk_files)

      # Ensure .prettierignore includes generated files
      generated_count = generated_count + ensure_prettierignore(otp_app)

      if generated_count > 0 do
        Mix.shell().info("\nGenerated #{generated_count} file(s)")

        # Check for required dependencies and warn if missing
        check_frontend_dependencies(otp_app)
      end

      {:ok, []}
    end
  end

  # ============================================================================
  # Dependency Checking
  # ============================================================================

  defp check_frontend_dependencies(otp_app) do
    sdk_base = sdk_base_path(otp_app)

    if sdk_base do
      frontend_root = find_frontend_root(sdk_base)

      if frontend_root do
        package_json_path = Path.join(frontend_root, "package.json")

        if File.exists?(package_json_path) do
          case File.read(package_json_path) do
            {:ok, content} ->
              case Jason.decode(content) do
                {:ok, package} ->
                  deps = Map.get(package, "dependencies", %{})
                  dev_deps = Map.get(package, "devDependencies", %{})
                  all_deps = Map.merge(deps, dev_deps)

                  missing = []

                  missing =
                    if Map.has_key?(all_deps, "zustand") do
                      missing
                    else
                      ["zustand" | missing]
                    end

                  missing =
                    if Map.has_key?(all_deps, "phoenix") do
                      missing
                    else
                      ["phoenix" | missing]
                    end

                  if length(missing) > 0 do
                    missing_str = Enum.join(missing, " ")

                    Mix.shell().info([
                      "\n",
                      :yellow,
                      "⚠ Missing peer dependencies:",
                      :reset,
                      " #{missing_str}\n",
                      "  Install with: ",
                      :cyan,
                      "npm install #{missing_str}",
                      :reset,
                      "\n"
                    ])
                  end

                _ ->
                  :ok
              end

            _ ->
              :ok
          end
        end
      end
    end
  end

  # ============================================================================
  # Warnings and Diagnostics
  # ============================================================================

  defp warn_if_no_dispatch_resources(otp_app, events, counters) do
    # Only warn if we have no events AND no counters - likely misconfiguration
    if length(events) == 0 and length(counters) == 0 do
      configured_domains = get_domains(otp_app)

      Mix.shell().info([
        "\n",
        :yellow,
        "⚠ No AshDispatch events or counters found.",
        :reset,
        "\n\n",
        "  If you have resources using ",
        :cyan,
        "AshDispatch.Resource",
        :reset,
        ", ensure their domains\n",
        "  are listed in your config:\n\n",
        :faint,
        "    # config/config.exs\n",
        "    config :#{otp_app}, :ash_domains, [\n",
        "      # ... your existing domains ...\n",
        "      MyApp.Notifications,  # If using AshDispatch notifications\n",
        "      MyApp.Deliveries,     # If using AshDispatch delivery receipts\n",
        "    ]\n",
        :reset,
        "\n",
        "  Currently configured domains: ",
        :cyan,
        if(configured_domains == [], do: "(none)", else: inspect(configured_domains)),
        :reset,
        "\n"
      ])
    end
  end

  # ============================================================================
  # Counter Discovery
  # ============================================================================

  defp discover_counters(otp_app) do
    domains = get_domains(otp_app)

    domains
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.filter(&uses_ash_dispatch?/1)
    |> Enum.flat_map(&extract_counters/1)
  end

  defp get_domains(otp_app) do
    # Get domains from app config
    app_domains = Application.get_env(otp_app, :ash_domains, [])

    # Also check ash_dispatch domains config
    dispatch_domains = Application.get_env(:ash_dispatch, :domains, [])

    (app_domains ++ dispatch_domains) |> Enum.uniq()
  end

  defp uses_ash_dispatch?(resource) do
    AshDispatch.Resource in Spark.extensions(resource)
  end

  defp extract_counters(resource) do
    resource_name =
      resource
      |> Module.split()
      |> List.last()
      |> Macro.underscore()

    case Spark.Dsl.Extension.get_entities(resource, [:counters]) do
      [] ->
        []

      counters ->
        Enum.map(counters, fn counter ->
          %{
            name: counter.counter_name || counter.name,
            source: resource_name,
            group: counter.group || :ungrouped,
            audience: counter.audience,
            global?: Map.get(counter, :global?, false),
            invalidates: counter.invalidates || []
          }
        end)
    end
  rescue
    _ -> []
  end

  # ============================================================================
  # Missing File Detection
  # ============================================================================

  defp check_typescript_events_status(otp_app, events) do
    output_path = sdk_path(otp_app, "events.ts")

    if output_path && length(events) > 0 do
      expected_content = generate_events_typescript_content(events) |> ensure_trailing_newline()
      file_exists = File.exists?(output_path)
      current_content = if file_exists, do: File.read!(output_path), else: ""

      # Compare without timestamp and trailing whitespace (handles formatter differences)
      expected_normalized = normalize_for_comparison(expected_content)
      current_normalized = normalize_for_comparison(current_content)

      if expected_normalized != current_normalized do
        %{
          path: output_path,
          content: expected_content,
          event_count: length(events),
          is_new: !file_exists
        }
      else
        nil
      end
    else
      nil
    end
  end

  defp check_typescript_types_status(otp_app, counters) do
    output_path = sdk_path(otp_app, "types.ts")

    if output_path && length(counters) > 0 do
      expected_content = generate_types_typescript_content(counters) |> ensure_trailing_newline()
      file_exists = File.exists?(output_path)
      current_content = if file_exists, do: File.read!(output_path), else: ""

      # Compare without timestamp and trailing whitespace (handles formatter differences)
      expected_normalized = normalize_for_comparison(expected_content)
      current_normalized = normalize_for_comparison(current_content)

      if expected_normalized != current_normalized do
        %{
          path: output_path,
          content: expected_content,
          counter_count: length(Enum.uniq_by(counters, & &1.name)),
          is_new: !file_exists
        }
      else
        nil
      end
    else
      nil
    end
  end

  defp check_sdk_status(otp_app) do
    base_path = sdk_base_path(otp_app)

    if base_path do
      sdk_files = [
        {"store.ts", &generate_store_content/0},
        {"channel.ts", &generate_channel_content/0},
        {"index.ts", &generate_index_content/0},
        {"hooks/use-channel.ts", &generate_use_channel_content/0},
        {"hooks/use-counter.ts", &generate_use_counter_content/0},
        {"hooks/use-notifications.ts", &generate_use_notifications_content/0},
        {"notification-provider.tsx", &generate_notification_provider_content/0},
        {"notification-bell.tsx", &generate_notification_bell_content/0},
        {"README.md", &generate_readme_content/0}
      ]

      Enum.filter(sdk_files, fn {filename, _generator} ->
        path = Path.join(base_path, filename)
        !File.exists?(path)
      end)
      |> Enum.map(fn {filename, generator} ->
        %{path: Path.join(base_path, filename), content: generator.()}
      end)
    else
      []
    end
  end

  defp remove_timestamp(content) do
    Regex.replace(~r/\/\/ Generated at: .*\n/, content, "")
  end

  # Normalize content for comparison - strips timestamp and trailing whitespace
  defp normalize_for_comparison(content) do
    content
    |> remove_timestamp()
    |> String.trim_trailing()
  end

  # Ensure content ends with exactly one newline (prettier standard)
  defp ensure_trailing_newline(content) do
    String.trim_trailing(content) <> "\n"
  end

  defp count_missing(missing) do
    length(missing.templates) +
      length(missing.event_modules) +
      if(missing.typescript_events, do: 1, else: 0) +
      if(missing.typescript_types, do: 1, else: 0) +
      length(missing.sdk_files)
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

    events_diff =
      if missing.typescript_events do
        %{missing.typescript_events.path => missing.typescript_events.content}
      else
        %{}
      end

    types_diff =
      if missing.typescript_types do
        %{missing.typescript_types.path => missing.typescript_types.content}
      else
        %{}
      end

    sdk_diff = Map.new(missing.sdk_files, fn f -> {f.path, f.content} end)

    template_diff
    |> Map.merge(module_diff)
    |> Map.merge(events_diff)
    |> Map.merge(types_diff)
    |> Map.merge(sdk_diff)
  end

  # ============================================================================
  # Dry Run Output
  # ============================================================================

  defp print_dry_run(missing, counters, sdk_enabled) do
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

    if missing.typescript_events do
      Mix.shell().info("\n#{IO.ANSI.cyan()}TypeScript event types to generate:#{IO.ANSI.reset()}")
      Mix.shell().info("  #{missing.typescript_events.path}")
    end

    if missing.typescript_types do
      Mix.shell().info(
        "\n#{IO.ANSI.cyan()}TypeScript counter types to generate:#{IO.ANSI.reset()}"
      )

      Mix.shell().info("  #{missing.typescript_types.path} (#{length(counters)} counters)")
    end

    if length(missing.sdk_files) > 0 do
      Mix.shell().info("\n#{IO.ANSI.cyan()}SDK files to generate:#{IO.ANSI.reset()}")

      Enum.each(missing.sdk_files, fn f ->
        Mix.shell().info("  #{f.path}")
      end)
    end

    unless sdk_enabled do
      Mix.shell().info(
        "\n#{IO.ANSI.yellow()}TypeScript SDK skipped#{IO.ANSI.reset()} (ash_typescript not configured)"
      )
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

    length(templates)
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

    length(modules)
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
  # TypeScript Events Generation
  # ============================================================================

  defp generate_typescript_events(nil), do: 0

  defp generate_typescript_events(events_info) do
    dir = Path.dirname(events_info.path)
    File.mkdir_p!(dir)

    File.write!(events_info.path, events_info.content)

    action = if events_info.is_new, do: "creating ", else: "updating "
    detail = "(#{events_info.event_count} events)"

    Mix.shell().info([
      :green,
      "* #{action}",
      :reset,
      events_info.path,
      " ",
      :faint,
      detail,
      :reset
    ])

    1
  end

  defp generate_events_typescript_content(events) do
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

  # ============================================================================
  # TypeScript Types (Counters) Generation
  # ============================================================================

  defp generate_typescript_types(nil, _counters), do: 0

  defp generate_typescript_types(types_info, _counters) do
    dir = Path.dirname(types_info.path)
    File.mkdir_p!(dir)

    File.write!(types_info.path, types_info.content)

    action = if types_info.is_new, do: "creating ", else: "updating "
    detail = "(#{types_info.counter_count} counters)"

    Mix.shell().info([
      :green,
      "* #{action}",
      :reset,
      types_info.path,
      " ",
      :faint,
      detail,
      :reset
    ])

    1
  end

  defp generate_types_typescript_content(counters) do
    # Sort by name for deterministic output
    unique = counters |> Enum.uniq_by(& &1.name) |> Enum.sort_by(& &1.name)
    grouped = Enum.group_by(unique, & &1.group)
    merged_metadata = merge_counter_metadata(counters)
    by_source = Enum.group_by(counters, & &1.source)

    header = """
    // Auto-generated by mix ash_dispatch.gen
    // Do not edit manually
    // Generated at: #{DateTime.utc_now() |> DateTime.to_iso8601()}

    """

    # Generate type definitions for each group
    type_defs =
      grouped
      |> Enum.sort_by(fn {group, _} -> to_string(group) end)
      |> Enum.map(fn {group, group_counters} ->
        type_name = group_type_name(group)

        fields =
          Enum.map_join(group_counters, "\n", fn c ->
            "  #{c.name}: number;"
          end)

        """
        export type #{type_name} = {
        #{fields}
        };
        """
      end)
      |> Enum.join("\n")

    # Generate combined type
    all_types =
      grouped
      |> Map.keys()
      |> Enum.sort_by(&to_string/1)
      |> Enum.map(&group_type_name/1)
      |> Enum.join(" & ")

    combined_type = """
    export type AllCounters = #{all_types};
    """

    # Generate default counters
    default_counter_fields =
      unique
      |> Enum.map(fn c -> "  #{c.name}: 0," end)
      |> Enum.join("\n")

    default_counters = """
    /**
     * Default counter values (all initialized to 0).
     * Use in your store initialization.
     */
    export const DEFAULT_COUNTERS: AllCounters = {
    #{default_counter_fields}
    };
    """

    # Generate counter names constant grouped by source
    counter_const =
      by_source
      |> Enum.sort_by(fn {source, _} -> source end)
      |> Enum.map(fn {source, source_counters} ->
        # Deduplicate counters by name within each source
        unique_source_counters = Enum.uniq_by(source_counters, & &1.name)

        fields =
          Enum.map_join(unique_source_counters, "\n", fn c ->
            "    #{c.name}: \"#{c.name}\","
          end)

        "  #{source}: {\n#{fields}\n  },"
      end)
      |> Enum.join("\n")

    counters_object = """
    export const COUNTERS = {
    #{counter_const}
    } as const;
    """

    # Generate counter metadata
    metadata_entries =
      merged_metadata
      |> Enum.map(fn c ->
        invalidates_str = c.invalidates |> Enum.map(fn i -> "\"#{i}\"" end) |> Enum.join(", ")
        sources_str = c.sources |> Enum.map(fn s -> "\"#{s}\"" end) |> Enum.join(", ")

        "  #{c.name}: {\n    audience: \"#{c.audience}\",\n    invalidates: [#{invalidates_str}],\n    sources: [#{sources_str}],\n  },"
      end)
      |> Enum.join("\n")

    metadata = """
    export const COUNTER_METADATA = {
    #{metadata_entries}
    } as const;
    """

    # Generate CounterName type and accessor helpers
    counter_names =
      unique
      |> Enum.map(fn c -> "\"#{c.name}\"" end)
      |> Enum.join(" | ")

    camel_case_fields =
      unique
      |> Enum.map(fn c ->
        camel = snake_to_camel(to_string(c.name))
        {camel, c.name}
      end)

    accessor_type_fields =
      camel_case_fields
      |> Enum.map(fn {camel, _snake} -> "  #{camel}: number;" end)
      |> Enum.join("\n")

    accessor_impl =
      camel_case_fields
      |> Enum.map(fn {camel, snake} -> "    #{camel}: counters.#{snake}," end)
      |> Enum.join("\n")

    accessor_helper = """
    export type CounterName = #{counter_names};

    export function isValidCounter(name: string): name is CounterName {
      return name in COUNTER_METADATA;
    }

    /**
     * Type for camelCase counter accessors.
     * Use with getCounterAccessors() or in your useCounters hook.
     */
    export type CounterAccessors = {
    #{accessor_type_fields}
    };

    /**
     * Convert snake_case counters to camelCase accessors.
     * Auto-generated from counter definitions.
     *
     * @example
     * ```tsx
     * // In your useCounters hook:
     * export function useCounters() {
     *   const counters = useCounterStore((state) => state.counters)
     *   return {
     *     ...getCounterAccessors(counters),
     *     counters,
     *   }
     * }
     * ```
     */
    export function getCounterAccessors(counters: AllCounters): CounterAccessors {
      return {
    #{accessor_impl}
      };
    }
    """

    header <>
      type_defs <>
      "\n" <>
      combined_type <>
      "\n" <>
      default_counters <> "\n" <> counters_object <> "\n" <> metadata <> "\n" <> accessor_helper
  end

  defp merge_counter_metadata(counters) do
    counters
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {name, instances} ->
      sources = instances |> Enum.map(& &1.source) |> Enum.uniq() |> Enum.sort()

      invalidates =
        instances
        |> Enum.flat_map(& &1.invalidates)
        |> Enum.uniq()
        |> Enum.sort()

      audiences = instances |> Enum.map(& &1.audience) |> Enum.uniq()
      audience = List.first(audiences)
      group = List.first(instances).group

      %{
        name: name,
        group: group,
        audience: audience,
        invalidates: invalidates,
        sources: sources
      }
    end)
    # Sort by name for deterministic output
    |> Enum.sort_by(& &1.name)
  end

  defp snake_to_camel(string) do
    [first | rest] = String.split(string, "_")
    first <> Enum.map_join(rest, "", &String.capitalize/1)
  end

  defp group_type_name(:ungrouped), do: "UngroupedCounters"

  defp group_type_name(group) do
    group
    |> to_string()
    |> Macro.camelize()
    |> Kernel.<>("Counters")
  end

  # ============================================================================
  # SDK Files Generation
  # ============================================================================

  defp generate_sdk_files(sdk_files) do
    Enum.each(sdk_files, fn file_info ->
      dir = Path.dirname(file_info.path)
      File.mkdir_p!(dir)

      File.write!(file_info.path, file_info.content)

      Mix.shell().info([:green, "* creating ", :reset, file_info.path])
    end)

    length(sdk_files)
  end

  # ============================================================================
  # Prettier Ignore
  # ============================================================================

  @prettierignore_header "# Auto-generated by AshDispatch - do not edit this section"
  @prettierignore_footer "# End AshDispatch section"

  defp ensure_prettierignore(otp_app) do
    case find_prettierignore_path(otp_app) do
      nil ->
        0

      {prettierignore_path, paths_to_ignore} ->
        if update_prettierignore(prettierignore_path, paths_to_ignore) do
          action = if File.exists?(prettierignore_path), do: "updating ", else: "creating "
          Mix.shell().info([:green, "* #{action}", :reset, prettierignore_path])
          1
        else
          0
        end
    end
  end

  defp find_prettierignore_path(otp_app) do
    sdk_base = sdk_base_path(otp_app)
    ash_ts_output = Application.get_env(:ash_typescript, :output_file)

    if sdk_base do
      # Find the frontend project root (where package.json lives)
      frontend_root = find_frontend_root(sdk_base)

      if frontend_root do
        prettierignore_path = Path.join(frontend_root, ".prettierignore")

        # Calculate relative paths from frontend root
        sdk_relative = Path.relative_to(sdk_base, frontend_root)

        paths = [sdk_relative <> "/"]

        # Also add ash_rpc.ts if it exists
        paths =
          if ash_ts_output do
            rpc_relative = Path.relative_to(ash_ts_output, frontend_root)
            paths ++ [rpc_relative]
          else
            paths
          end

        {prettierignore_path, paths}
      else
        nil
      end
    else
      nil
    end
  end

  defp find_frontend_root(path) do
    # Walk up the directory tree looking for package.json
    cond do
      File.exists?(Path.join(path, "package.json")) ->
        path

      path == "/" or path == "." ->
        nil

      true ->
        find_frontend_root(Path.dirname(path))
    end
  end

  defp update_prettierignore(path, paths_to_ignore) do
    existing_content = if File.exists?(path), do: File.read!(path), else: ""

    # Check if all paths are already in the file
    all_present =
      Enum.all?(paths_to_ignore, fn p ->
        String.contains?(existing_content, p)
      end)

    if all_present do
      false
    else
      # Generate the AshDispatch section
      section_content =
        [@prettierignore_header] ++
          Enum.map(paths_to_ignore, &"#{&1}") ++
          [@prettierignore_footer]

      new_section = Enum.join(section_content, "\n")

      # Check if we already have an AshDispatch section
      new_content =
        if String.contains?(existing_content, @prettierignore_header) do
          # Replace existing section
          Regex.replace(
            ~r/#{Regex.escape(@prettierignore_header)}.*?#{Regex.escape(@prettierignore_footer)}/s,
            existing_content,
            new_section
          )
        else
          # Append new section
          if existing_content == "" do
            new_section <> "\n"
          else
            String.trim_trailing(existing_content) <> "\n\n" <> new_section <> "\n"
          end
        end

      File.write!(path, new_content)
      true
    end
  end

  # ============================================================================
  # Path Helpers
  # ============================================================================

  # Default output path matching ash_typescript's installer default
  @default_ash_typescript_output "assets/js/ash_rpc.ts"

  defp typescript_sdk_enabled?(otp_app) do
    # SDK generation requires either:
    # 1. Explicit sdk_output_path in ash_dispatch config
    # 2. Valid ash_typescript :output_file configuration
    # 3. Any domain using AshTypescript.Rpc (uses default path)
    explicit_path =
      Application.get_env(:ash_dispatch, :sdk_output_path) ||
        Application.get_env(otp_app, :ash_dispatch)[:sdk_output_path]

    ash_ts_output = Application.get_env(:ash_typescript, :output_file)

    cond do
      explicit_path != nil -> true
      ash_ts_output != nil and is_binary(ash_ts_output) and ash_ts_output != "" -> true
      ash_typescript_in_use?(otp_app) -> true
      true -> false
    end
  end

  defp sdk_base_path(otp_app) do
    explicit_path =
      Application.get_env(:ash_dispatch, :sdk_output_path) ||
        Application.get_env(otp_app, :ash_dispatch)[:sdk_output_path]

    if explicit_path do
      explicit_path
    else
      # Use configured output_file, or default if ash_typescript is in use
      ash_ts_output =
        Application.get_env(:ash_typescript, :output_file) ||
          if(ash_typescript_in_use?(otp_app), do: @default_ash_typescript_output)

      if ash_ts_output do
        base_dir = Path.dirname(ash_ts_output)
        Path.join(base_dir, "ash-dispatch")
      else
        nil
      end
    end
  end

  defp ash_typescript_in_use?(otp_app) do
    # Check if any domain uses the AshTypescript.Rpc extension
    if Code.ensure_loaded?(AshTypescript.Rpc) do
      domains = Application.get_env(otp_app, :ash_domains, [])

      Enum.any?(domains, fn domain ->
        Code.ensure_loaded?(domain) and
          function_exported?(domain, :spark_dsl_config, 0) and
          has_ash_typescript_extension?(domain)
      end)
    else
      false
    end
  end

  defp has_ash_typescript_extension?(domain) do
    try do
      extensions = Spark.extensions(domain)
      AshTypescript.Rpc in extensions
    rescue
      _ -> false
    end
  end

  defp sdk_path(otp_app, filename) do
    base = sdk_base_path(otp_app)
    if base, do: Path.join(base, filename), else: nil
  end

  defp channel_topic do
    Application.get_env(:ash_dispatch, :channel_topic, "user")
  end

  # ============================================================================
  # SDK Content Generators
  # ============================================================================

  defp generate_store_content do
    """
    // Auto-generated by mix ash_dispatch.gen
    // Zustand store for counter state

    import { create } from 'zustand'
    import { DEFAULT_COUNTERS, type AllCounters, type CounterName } from './types'

    export interface CounterState {
      counters: AllCounters
      setCounters: (counters: Partial<AllCounters>) => void
      setCounter: (key: CounterName, value: number) => void
      incrementCounter: (key: CounterName, delta?: number) => void
      resetCounters: () => void
    }

    export const useCounterStore = create<CounterState>()((set) => ({
      counters: DEFAULT_COUNTERS,

      setCounters: (newCounters: Partial<AllCounters>) => {
        set((state: CounterState) => ({
          counters: { ...state.counters, ...newCounters },
        }))
      },

      setCounter: (key: CounterName, value: number) => {
        set((state: CounterState) => ({
          counters: { ...state.counters, [key]: value },
        }))
      },

      incrementCounter: (key: CounterName, delta: number = 1) => {
        set((state: CounterState) => ({
          counters: { ...state.counters, [key]: Math.max(0, state.counters[key] + delta) },
        }))
      },

      resetCounters: () => {
        set({ counters: DEFAULT_COUNTERS })
      },
    }))
    """
  end

  defp generate_channel_content do
    """
    // Auto-generated by mix ash_dispatch.gen
    // Phoenix channel utilities

    import { Socket, Channel } from 'phoenix'

    export interface ChannelConfig {
      socketUrl: string
      userToken: string
      userId: string
    }

    export function createUserChannel(config: ChannelConfig): Channel {
      const socket = new Socket(config.socketUrl, {
        params: { token: config.userToken }
      })

      socket.connect()

      const channel = socket.channel(`#{channel_topic()}:${config.userId}`, {})

      return channel
    }
    """
  end

  defp generate_index_content do
    """
    // Auto-generated by mix ash_dispatch.gen
    // Do not edit manually

    // Core types and store
    export * from './types'
    export * from './store'
    export * from './channel'

    // Hooks
    export { useChannel } from './hooks/use-channel'
    export { useCounter } from './hooks/use-counter'
    export { useNotifications, type Notification, type UseNotificationsOptions, type UseNotificationsReturn } from './hooks/use-notifications'

    // Components
    export { NotificationProvider, useNotificationContext, type NotificationProviderProps } from './notification-provider'
    export { NotificationBell, type NotificationBellProps } from './notification-bell'
    """
  end

  defp generate_use_channel_content do
    """
    // Auto-generated by mix ash_dispatch.gen
    // Hook for managing Phoenix channel connection

    import { useEffect, useRef } from 'react'
    import { Channel } from 'phoenix'
    import { useCounterStore, type CounterState } from '../store'
    import { isValidCounter, type AllCounters } from '../types'

    interface UseChannelOptions {
      channel: Channel | null
      onNotification?: (notification: unknown) => void
    }

    interface ChannelJoinResponse {
      counters?: Partial<AllCounters>
    }

    interface CounterUpdatePayload {
      counter: string
      value: number
    }

    export function useChannel({ channel, onNotification }: UseChannelOptions) {
      const setCounter = useCounterStore((state: CounterState) => state.setCounter)
      const joinedRef = useRef(false)

      useEffect(() => {
        if (!channel || joinedRef.current) return

        channel.join()
          .receive('ok', (response: ChannelJoinResponse) => {
            console.log('[AshDispatch] Channel joined', response)
            joinedRef.current = true

            // Set initial counters
            if (response.counters) {
              Object.entries(response.counters).forEach(([key, value]) => {
                if (isValidCounter(key)) {
                  setCounter(key, value as number)
                }
              })
            }
          })
          .receive('error', (err: unknown) => {
            console.error('[AshDispatch] Channel join error', err)
          })

        // Listen for counter updates
        channel.on('counter_updated', (payload: CounterUpdatePayload) => {
          const counterName = payload.counter
          if (isValidCounter(counterName)) {
            setCounter(counterName, payload.value)
          }
        })

        // Listen for notifications
        channel.on('notification', (payload: unknown) => {
          onNotification?.(payload)
        })

        return () => {
          if (joinedRef.current) {
            channel.leave()
            joinedRef.current = false
          }
        }
      }, [channel, setCounter, onNotification])
    }
    """
  end

  defp generate_use_counter_content do
    """
    // Auto-generated by mix ash_dispatch.gen
    // Hook for accessing a single counter value

    import { useCounterStore, type CounterState } from '../store'
    import type { CounterName } from '../types'

    /**
     * Access a single counter value from the store.
     *
     * @example
     * ```tsx
     * const unreadCount = useCounter('unread_notifications')
     * ```
     */
    export function useCounter(name: CounterName): number {
      return useCounterStore((state: CounterState) => state.counters[name])
    }
    """
  end

  defp generate_use_notifications_content do
    """
    // Auto-generated by mix ash_dispatch.gen
    // Complete hook for notification state and actions
    // Connects to your Ash RPC notifications and Phoenix channel

    "use client"

    import { useCallback, useEffect, useRef, useState } from 'react'
    import { Socket, Channel } from 'phoenix'
    import { useCounterStore, type CounterState } from '../store'
    import { isValidCounter, type CounterName } from '../types'

    // ============================================================================
    // Types
    // ============================================================================

    /**
     * Notification type from the backend.
     * Matches the Ash Notification resource fields.
     */
    export interface Notification {
      id: string
      title: string
      message: string
      type: 'info' | 'success' | 'warning' | 'error'
      actionUrl: string | null
      actionLabel: string | null
      read: boolean
      readAt: string | null
      occurredAt: string
      insertedAt: string
    }

    export interface UseNotificationsOptions {
      /** User ID for fetching notifications. Required. */
      userId: string | null
      /** Whether to enable the hook. Defaults to true. */
      enabled?: boolean
      /** RPC function to list notifications - pass your ash_typescript generated function directly */
      listNotifications: ListNotificationsFn
      /** RPC function to mark a notification as read - pass your ash_typescript generated function directly */
      markNotificationAsRead: MarkAsReadFn
      /** RPC function to mark all notifications as read - pass your ash_typescript generated function directly */
      markAllNotificationsAsRead: MarkAllAsReadFn
      /** Function to build CSRF headers */
      buildCSRFHeaders: () => Record<string, string>
    }

    export interface UseNotificationsReturn {
      notifications: Notification[]
      unreadCount: number
      isLoading: boolean
      error: string | null
      isConnected: boolean
      markAsRead: (notificationId: string) => Promise<void>
      markAllAsRead: () => Promise<void>
      refresh: () => Promise<void>
    }

    // Flexible RPC function types - compatible with ash_typescript generated functions
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    type ListNotificationsFn = (config: { input: { userId: string }; fields: any[]; headers?: Record<string, string> }) => Promise<{ success: boolean; data?: any }>
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    type MarkAsReadFn = (config: { identity: string; fields?: any[]; headers?: Record<string, string> }) => Promise<{ success: boolean; data?: any }>
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    type MarkAllAsReadFn = (config: { input: { userId: string }; headers?: Record<string, string> }) => Promise<{ success: boolean }>

    // ============================================================================
    // Hook Implementation
    // ============================================================================

    /**
     * Complete notification management hook.
     *
     * Handles:
     * - Fetching notifications via RPC
     * - Real-time updates via Phoenix channel
     * - Mark as read / mark all as read
     * - Unread counter synchronization
     *
     * @example
     * ```tsx
     * import { useNotifications } from '@/lib/generated/ash-dispatch'
     * import {
     *   listNotifications,
     *   markNotificationAsRead,
     *   markAllNotificationsAsRead,
     *   buildCSRFHeaders,
     * } from '@/lib/generated/ash_rpc'
     *
     * function NotificationList() {
     *   const { user } = useAuth()
     *   const {
     *     notifications,
     *     unreadCount,
     *     isLoading,
     *     markAsRead,
     *     markAllAsRead,
     *   } = useNotifications({
     *     userId: user?.id ?? null,
     *     listNotifications,
     *     markNotificationAsRead,
     *     markAllNotificationsAsRead,
     *     buildCSRFHeaders,
     *   })
     *
     *   return (
     *     <div>
     *       <span>Unread: {unreadCount}</span>
     *       {notifications.map((n) => (
     *         <div key={n.id} onClick={() => markAsRead(n.id)}>
     *           {n.title}
     *         </div>
     *       ))}
     *     </div>
     *   )
     * }
     * ```
     */
    export function useNotifications({
      userId,
      enabled = true,
      listNotifications,
      markNotificationAsRead,
      markAllNotificationsAsRead,
      buildCSRFHeaders,
    }: UseNotificationsOptions): UseNotificationsReturn {
      const [notifications, setNotifications] = useState<Notification[]>([])
      const [isLoading, setIsLoading] = useState(true)
      const [error, setError] = useState<string | null>(null)
      const [isConnected, setIsConnected] = useState(false)

      const socketRef = useRef<Socket | null>(null)
      const channelRef = useRef<Channel | null>(null)

      // Use the Zustand counter store
      const setCounter = useCounterStore((state: CounterState) => state.setCounter)
      const incrementCounter = useCounterStore((state: CounterState) => state.incrementCounter)
      const unreadCount = useCounterStore((state: CounterState) => state.counters.unread_notifications)

      // Fetch notifications from backend
      const fetchNotifications = useCallback(async () => {
        if (!enabled || !userId) return

        setIsLoading(true)
        setError(null)

        try {
          const result = await listNotifications({
            headers: buildCSRFHeaders(),
            fields: [
              'id',
              'title',
              'message',
              'type',
              'actionUrl',
              'actionLabel',
              'read',
              'readAt',
              'occurredAt',
              'insertedAt',
            ],
            input: { userId },
          })

          if (result.success) {
            const data = result.data
            setNotifications(data)

            // Update the unread counter
            const unread = data.filter((n: Notification) => !n.read).length
            setCounter('unread_notifications', unread)
          } else {
            setError('Failed to fetch notifications')
          }
        } catch (err) {
          setError(err instanceof Error ? err.message : 'Failed to fetch notifications')
        } finally {
          setIsLoading(false)
        }
      }, [enabled, userId, listNotifications, buildCSRFHeaders, setCounter])

      // Mark single notification as read
      const markAsRead = useCallback(
        async (notificationId: string) => {
          try {
            const result = await markNotificationAsRead({
              headers: buildCSRFHeaders(),
              identity: notificationId,
              fields: ['id', 'read'],
            })

            if (result.success) {
              setNotifications((prev) =>
                prev.map((n) => (n.id === notificationId ? { ...n, read: true } : n))
              )
              // Decrement counter (uses functional update, no stale closure)
              incrementCounter('unread_notifications', -1)
            }
          } catch (err) {
            console.error('[AshDispatch] Failed to mark notification as read:', err)
          }
        },
        [markNotificationAsRead, buildCSRFHeaders, incrementCounter]
      )

      // Mark all notifications as read
      const markAllAsRead = useCallback(async () => {
        if (!userId) return

        try {
          const result = await markAllNotificationsAsRead({
            headers: buildCSRFHeaders(),
            input: { userId },
          })

          if (result.success) {
            setNotifications((prev) => prev.map((n) => ({ ...n, read: true })))
            setCounter('unread_notifications', 0)
          }
        } catch (err) {
          console.error('[AshDispatch] Failed to mark all notifications as read:', err)
        }
      }, [userId, markAllNotificationsAsRead, buildCSRFHeaders, setCounter])

      // Connect to Phoenix channel for real-time updates
      const connectChannel = useCallback(async () => {
        if (!userId || !enabled) return

        try {
          // Fetch socket token from your API
          const response = await fetch('/api/inbox/socket-token', {
            headers: buildCSRFHeaders(),
            credentials: 'include',
          })

          if (!response.ok) {
            return // Socket connection is optional
          }

          const data = await response.json()
          if (!data.success) {
            return
          }

          const token = data.data.token

          // Create socket connection
          const socket = new Socket('/socket', {
            params: { token },
          })

          socket.onError(() => setIsConnected(false))
          socket.onClose(() => setIsConnected(false))
          socket.connect()
          socketRef.current = socket

          // Join the channel for notifications (configurable via :channel_topic)
          const channel = socket.channel(`#{channel_topic()}:${userId}`, {})

          // Listen for new notifications
          channel.on('new_notification', (notification: Notification) => {
            setNotifications((prev) => [notification, ...prev])
            if (!notification.read) {
              // Use incrementCounter to avoid stale closure issues
              incrementCounter('unread_notifications', 1)
            }
          })

          // Listen for counter updates (from UserChannel.broadcast_counter or custom broadcast)
          channel.on('counter_updated', (payload: { counter: string; value: number; metadata?: { invalidate_queries?: string[] } }) => {
            if (isValidCounter(payload.counter)) {
              setCounter(payload.counter as CounterName, payload.value)
            }
          })

          channel
            .join()
            .receive('ok', () => setIsConnected(true))
            .receive('error', () => setIsConnected(false))

          channelRef.current = channel
        } catch {
          // Socket connection is optional
        }
      }, [userId, enabled, buildCSRFHeaders, setCounter, incrementCounter])

      // Initial fetch
      useEffect(() => {
        fetchNotifications()
      }, [fetchNotifications])

      // Connect to channel
      useEffect(() => {
        connectChannel()

        return () => {
          if (channelRef.current) {
            channelRef.current.leave()
            channelRef.current = null
          }
          if (socketRef.current) {
            socketRef.current.disconnect()
            socketRef.current = null
          }
        }
      }, [connectChannel])

      return {
        notifications,
        unreadCount,
        isLoading,
        error,
        isConnected,
        markAsRead,
        markAllAsRead,
        refresh: fetchNotifications,
      }
    }
    """
  end

  # ============================================================================
  # Additional SDK Generators (Provider, UI Components, README)
  # ============================================================================

  defp generate_notification_provider_content do
    """
    // Auto-generated by mix ash_dispatch.gen
    // Provider component that initializes notification state

    "use client"

    import { createContext, useContext, type ReactNode } from 'react'
    import { useNotifications, type UseNotificationsReturn, type UseNotificationsOptions } from './hooks/use-notifications'

    // ============================================================================
    // Context
    // ============================================================================

    const NotificationContext = createContext<UseNotificationsReturn | null>(null)

    /**
     * Hook to access notification context.
     * Must be used within a NotificationProvider.
     */
    export function useNotificationContext(): UseNotificationsReturn {
      const context = useContext(NotificationContext)
      if (!context) {
        throw new Error('useNotificationContext must be used within a NotificationProvider')
      }
      return context
    }

    // ============================================================================
    // Provider
    // ============================================================================

    export interface NotificationProviderProps extends UseNotificationsOptions {
      children: ReactNode
    }

    /**
     * Provider component that initializes notification state and Phoenix channel connection.
     *
     * Wrap your app (or authenticated layout) with this provider to enable
     * notification features throughout your application.
     *
     * @example
     * ```tsx
     * // In your app layout or authenticated wrapper:
     * import { NotificationProvider } from '@/lib/generated/ash-dispatch/notification-provider'
     * import {
     *   listNotifications,
     *   markNotificationAsRead,
     *   markAllNotificationsAsRead,
     *   buildCSRFHeaders,
     * } from '@/lib/generated/ash_rpc'
     *
     * function AuthenticatedLayout({ children }) {
     *   const { user } = useAuth()
     *
     *   return (
     *     <NotificationProvider
     *       userId={user?.id ?? null}
     *       listNotifications={listNotifications}
     *       markNotificationAsRead={markNotificationAsRead}
     *       markAllNotificationsAsRead={markAllNotificationsAsRead}
     *       buildCSRFHeaders={buildCSRFHeaders}
     *     >
     *       {children}
     *     </NotificationProvider>
     *   )
     * }
     * ```
     */
    export function NotificationProvider({
      children,
      ...options
    }: NotificationProviderProps) {
      const notificationState = useNotifications(options)

      return (
        <NotificationContext.Provider value={notificationState}>
          {children}
        </NotificationContext.Provider>
      )
    }
    """
  end

  defp generate_notification_bell_content do
    """
    // Auto-generated by mix ash_dispatch.gen
    // Drop-in notification bell component

    "use client"

    import { useState } from 'react'
    import { useNotificationContext } from './notification-provider'

    // ============================================================================
    // Types
    // ============================================================================

    export interface NotificationBellProps {
      /** Custom class name for the container */
      className?: string
      /** Custom icon component (defaults to bell SVG) */
      icon?: React.ReactNode
      /** Whether to show the notification count badge */
      showBadge?: boolean
      /** Maximum count to display (shows "99+" if exceeded) */
      maxCount?: number
      /** Callback when bell is clicked */
      onClick?: () => void
    }

    // ============================================================================
    // Default Icon
    // ============================================================================

    function BellIcon({ className }: { className?: string }) {
      return (
        <svg
          xmlns="http://www.w3.org/2000/svg"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth={2}
          strokeLinecap="round"
          strokeLinejoin="round"
          className={className}
        >
          <path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9" />
          <path d="M10.3 21a1.94 1.94 0 0 0 3.4 0" />
        </svg>
      )
    }

    // ============================================================================
    // Component
    // ============================================================================

    /**
     * Drop-in notification bell component with unread badge.
     *
     * Uses the NotificationContext, so must be placed within a NotificationProvider.
     *
     * @example
     * ```tsx
     * // Simple usage in header:
     * <NotificationBell onClick={() => setShowPanel(true)} />
     *
     * // With custom styling:
     * <NotificationBell
     *   className="text-gray-600 hover:text-gray-900"
     *   maxCount={99}
     * />
     *
     * // With custom icon (e.g., from @tabler/icons-react):
     * import { IconBell } from '@tabler/icons-react'
     * <NotificationBell icon={<IconBell className="size-5" />} />
     * ```
     */
    export function NotificationBell({
      className = '',
      icon,
      showBadge = true,
      maxCount = 99,
      onClick,
    }: NotificationBellProps) {
      const { unreadCount } = useNotificationContext()

      const displayCount = unreadCount > maxCount ? `${maxCount}+` : unreadCount

      return (
        <button
          type="button"
          onClick={onClick}
          className={`relative inline-flex items-center justify-center ${className}`}
          aria-label={`Notifications${unreadCount > 0 ? ` (${unreadCount} unread)` : ''}`}
        >
          {icon || <BellIcon className="size-5" />}

          {showBadge && unreadCount > 0 && (
            <span
              className="absolute -top-1 -right-1 flex items-center justify-center min-w-[1.25rem] h-5 px-1 text-xs font-medium text-white bg-red-500 rounded-full"
              aria-hidden="true"
            >
              {displayCount}
            </span>
          )}
        </button>
      )
    }
    """
  end

  defp generate_readme_content do
    """
    # AshDispatch TypeScript SDK

    Auto-generated TypeScript SDK for AshDispatch notifications and counters.

    ## Installation

    This SDK requires the following peer dependencies:

    ```bash
    npm install zustand phoenix
    # or
    pnpm add zustand phoenix
    # or
    yarn add zustand phoenix
    ```

    ## Quick Start

    ### 1. Wrap your app with the NotificationProvider

    ```tsx
    // app/layout.tsx or your authenticated layout
    import { NotificationProvider } from '@/lib/generated/ash-dispatch/notification-provider'
    import {
      listNotifications,
      markNotificationAsRead,
      markAllNotificationsAsRead,
      buildCSRFHeaders,
    } from '@/lib/generated/ash_rpc'

    export default function Layout({ children }) {
      const { user } = useAuth() // Your auth hook

      return (
        <NotificationProvider
          userId={user?.id ?? null}
          listNotifications={listNotifications}
          markNotificationAsRead={markNotificationAsRead}
          markAllNotificationsAsRead={markAllNotificationsAsRead}
          buildCSRFHeaders={buildCSRFHeaders}
        >
          {children}
        </NotificationProvider>
      )
    }
    ```

    ### 2. Add the NotificationBell to your header

    ```tsx
    import { NotificationBell } from '@/lib/generated/ash-dispatch/notification-bell'

    function Header() {
      const [showPanel, setShowPanel] = useState(false)

      return (
        <header>
          <NotificationBell onClick={() => setShowPanel(true)} />
        </header>
      )
    }
    ```

    ### 3. Access notifications anywhere

    ```tsx
    import { useNotificationContext } from '@/lib/generated/ash-dispatch/notification-provider'

    function NotificationList() {
      const { notifications, markAsRead, markAllAsRead, isLoading } = useNotificationContext()

      if (isLoading) return <div>Loading...</div>

      return (
        <div>
          <button onClick={markAllAsRead}>Mark all as read</button>
          {notifications.map((n) => (
            <div key={n.id} onClick={() => markAsRead(n.id)}>
              <strong>{n.title}</strong>
              <p>{n.message}</p>
            </div>
          ))}
        </div>
      )
    }
    ```

    ## Using Counters Directly

    For simple counter access without the full notification system:

    ```tsx
    import { useCounter } from '@/lib/generated/ash-dispatch'

    function Badge() {
      const unreadCount = useCounter('unread_notifications')
      return <span>{unreadCount}</span>
    }
    ```

    Or use the Zustand store directly:

    ```tsx
    import { useCounterStore } from '@/lib/generated/ash-dispatch/store'

    function CounterDisplay() {
      const counters = useCounterStore((state) => state.counters)
      return <pre>{JSON.stringify(counters, null, 2)}</pre>
    }
    ```

    ## Real-time Updates

    The SDK automatically connects to Phoenix channels when using `useNotifications` or `NotificationProvider`. Ensure your backend has:

    1. A socket endpoint at `/socket`
    2. A user channel at `user:{userId}`
    3. An endpoint at `/api/inbox/socket-token` that returns `{ success: true, data: { token: "..." } }`

    ## API Reference

    ### Hooks

    | Hook | Description |
    |------|-------------|
    | `useNotifications(options)` | Full notification management with RPC and channels |
    | `useCounter(name)` | Single counter value |
    | `useChannel(options)` | Low-level Phoenix channel connection |

    ### Components

    | Component | Description |
    |-----------|-------------|
    | `NotificationProvider` | Context provider for notification state |
    | `NotificationBell` | Drop-in bell icon with badge |

    ### Types

    | Type | Description |
    |------|-------------|
    | `Notification` | Notification object from backend |
    | `CounterName` | Union of all counter names |
    | `AllCounters` | Object type with all counter values |

    ## Generated Files

    | File | Description |
    |------|-------------|
    | `types.ts` | Counter types, defaults, and metadata |
    | `events.ts` | Event IDs and metadata |
    | `store.ts` | Zustand store for counters |
    | `channel.ts` | Phoenix channel utilities |
    | `hooks/use-channel.ts` | Channel connection hook |
    | `hooks/use-counter.ts` | Single counter hook |
    | `hooks/use-notifications.ts` | Complete notification hook |
    | `notification-provider.tsx` | React context provider |
    | `notification-bell.tsx` | Drop-in UI component |
    | `index.ts` | Re-exports |

    ---

    Generated by `mix ash_dispatch.gen`
    """
  end
end
