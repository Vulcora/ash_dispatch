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

      if generated_count > 0 do
        Mix.shell().info("\nGenerated #{generated_count} file(s)")
      end

      {:ok, []}
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
      expected_content = generate_events_typescript_content(events)
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

  defp check_typescript_types_status(otp_app, counters) do
    output_path = sdk_path(otp_app, "types.ts")

    if output_path && length(counters) > 0 do
      expected_content = generate_types_typescript_content(counters)
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

  defp check_sdk_status(otp_app) do
    base_path = sdk_base_path(otp_app)

    if base_path do
      sdk_files = [
        {"store.ts", &generate_store_content/0},
        {"channel.ts", &generate_channel_content/0},
        {"index.ts", &generate_index_content/0},
        {"hooks/use-channel.ts", &generate_use_channel_content/0},
        {"hooks/use-counter.ts", &generate_use_counter_content/0},
        {"hooks/use-notifications.ts", &generate_use_notifications_content/0}
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

    Mix.shell().info([:green, "* creating ", :reset, events_info.path])
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

    Mix.shell().info([:green, "* creating ", :reset, types_info.path])
    1
  end

  defp generate_types_typescript_content(counters) do
    unique = Enum.uniq_by(counters, & &1.name)
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
        fields =
          Enum.map_join(source_counters, "\n", fn c ->
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
  # Path Helpers
  # ============================================================================

  defp typescript_sdk_enabled?(otp_app) do
    # SDK generation requires either:
    # 1. Explicit sdk_output_path in ash_dispatch config
    # 2. Valid ash_typescript :output_file configuration
    explicit_path =
      Application.get_env(:ash_dispatch, :sdk_output_path) ||
        Application.get_env(otp_app, :ash_dispatch)[:sdk_output_path]

    ash_ts_output = Application.get_env(:ash_typescript, :output_file)

    cond do
      explicit_path != nil -> true
      ash_ts_output != nil and is_binary(ash_ts_output) and ash_ts_output != "" -> true
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
      ash_ts_output = Application.get_env(:ash_typescript, :output_file)

      if ash_ts_output do
        base_dir = Path.dirname(ash_ts_output)
        Path.join(base_dir, "ash-dispatch")
      else
        nil
      end
    end
  end

  defp sdk_path(otp_app, filename) do
    base = sdk_base_path(otp_app)
    if base, do: Path.join(base, filename), else: nil
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

    interface CounterState {
      counters: AllCounters
      setCounters: (counters: Partial<AllCounters>) => void
      setCounter: (key: CounterName, value: number) => void
      resetCounters: () => void
    }

    export const useCounterStore = create<CounterState>()((set) => ({
      counters: DEFAULT_COUNTERS,

      setCounters: (newCounters) => {
        set((state) => ({
          counters: { ...state.counters, ...newCounters },
        }))
      },

      setCounter: (key, value) => {
        set((state) => ({
          counters: { ...state.counters, [key]: value },
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

      const channel = socket.channel(`user:${config.userId}`, {})

      return channel
    }
    """
  end

  defp generate_index_content do
    """
    // Auto-generated by mix ash_dispatch.gen
    // Do not edit manually

    export * from './types'
    export * from './store'
    export * from './channel'
    export { useChannel } from './hooks/use-channel'
    export { useCounter } from './hooks/use-counter'
    export { useNotifications } from './hooks/use-notifications'
    """
  end

  defp generate_use_channel_content do
    """
    // Auto-generated by mix ash_dispatch.gen
    // Hook for managing Phoenix channel connection

    import { useEffect, useRef } from 'react'
    import { Channel } from 'phoenix'
    import { useCounterStore } from '../store'
    import { isValidCounter } from '../types'

    interface UseChannelOptions {
      channel: Channel | null
      onNotification?: (notification: unknown) => void
    }

    export function useChannel({ channel, onNotification }: UseChannelOptions) {
      const setCounter = useCounterStore((state) => state.setCounter)
      const joinedRef = useRef(false)

      useEffect(() => {
        if (!channel || joinedRef.current) return

        channel.join()
          .receive('ok', (response) => {
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
          .receive('error', (err) => {
            console.error('[AshDispatch] Channel join error', err)
          })

        // Listen for counter updates
        channel.on('counter_updated', (payload) => {
          const counterName = payload.counter as string
          if (isValidCounter(counterName)) {
            setCounter(counterName, payload.value)
          }
        })

        // Listen for notifications
        channel.on('notification', (payload) => {
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

    import { useCounterStore } from '../store'
    import type { CounterName } from '../types'

    export function useCounter(name: CounterName): number {
      return useCounterStore((state) => state.counters[name])
    }
    """
  end

  defp generate_use_notifications_content do
    """
    // Auto-generated by mix ash_dispatch.gen
    // Hook for notification state and actions

    import { useCallback } from 'react'
    import { useCounterStore } from '../store'

    // NOTE: This is a minimal implementation.
    // You'll need to integrate with your notification store and RPC calls.

    export function useNotifications() {
      const unreadCount = useCounterStore((state) => state.counters.unread_notifications)

      const markAsRead = useCallback(async (notificationId: string) => {
        // TODO: Call your RPC action
        // await markNotificationAsRead({ primaryKey: notificationId, fields: ["id", "read"] })
        console.log('markAsRead:', notificationId)
      }, [])

      const markAllAsRead = useCallback(async () => {
        // TODO: Call your RPC action
        // await markAllNotificationsAsRead({ input: { userId } })
        console.log('markAllAsRead')
      }, [])

      return {
        unreadCount,
        markAsRead,
        markAllAsRead,
      }
    }
    """
  end
end
