defmodule Mix.Tasks.AshDispatch.Gen.Previews do
  @shortdoc "Generates static HTML previews of all email templates"

  @moduledoc """
  Generates static HTML/text preview files for all AshDispatch events.

  This task renders each event template with its `sample_data/0` and outputs
  static files for easy preview, documentation, or CI validation.

  ## Usage

      mix ash_dispatch.gen.previews              # Generate all previews
      mix ash_dispatch.gen.previews --output priv/previews  # Custom output dir
      mix ash_dispatch.gen.previews --check      # CI mode - fail if outdated
      mix ash_dispatch.gen.previews --verbose    # Show detailed output

  ## Output Structure

  Previews are generated to `priv/ash_dispatch/previews/` by default:

      priv/ash_dispatch/previews/
      ├── index.html                           # Index with links to all previews
      ├── user.password_reset/
      │   ├── email.user.html                  # Rendered HTML email for user audience
      │   ├── email.user.txt                   # Rendered text email for user audience
      │   └── metadata.json                    # Event metadata (subject, from, etc.)
      ├── user.email_confirmation/
      │   ├── email.user.html
      │   ├── email.user.txt
      │   └── metadata.json
      └── orders.created/
          ├── email.user.html                  # User audience template
          ├── email.admin.html                 # Admin audience template
          ├── email.admin.summary.html         # Admin with 'summary' variant
          ├── email.user.txt
          ├── email.admin.txt
          ├── email.admin.summary.txt
          └── metadata.json

  ## Integration with Ash Codegen

  This task can be run alongside other generators:

      mix ash.codegen                          # Runs all extension codegens
      mix ash_dispatch.gen.previews            # Run after to generate previews

  ## Use Cases

  - **Design review**: Share rendered emails with designers
  - **Documentation**: Include in project docs
  - **CI validation**: Ensure templates render without errors
  - **Quick testing**: View all emails without running the app
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

    # Start the application to ensure all dependencies (Faker, Smokestack, etc.) are ready
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          output: :string,
          check: :boolean,
          verbose: :boolean
        ],
        aliases: [o: :output, v: :verbose]
      )

    otp_app = Mix.Project.config()[:app]
    output_dir = opts[:output] || default_output_dir(otp_app)

    if opts[:verbose] do
      Mix.shell().info("Generating previews to: #{output_dir}")
    end

    # Discover all events with modules that have sample_data
    events = discover_previewable_events(otp_app)

    if opts[:verbose] do
      Mix.shell().info("Found #{length(events)} previewable events")
    end

    if Enum.empty?(events) do
      Mix.shell().info("No events with sample_data/0 found. Nothing to generate.")
      {:ok, []}
    else
      # Generate previews
      results = generate_all_previews(events, output_dir, otp_app, opts)

      # Generate index
      generate_index(events, results, output_dir, otp_app)

      # Handle --check flag
      if opts[:check] do
        check_previews_up_to_date(results, output_dir)
      end

      total_files = count_files(results)
      Mix.shell().info("\nGenerated #{total_files} preview file(s) to #{output_dir}")

      {:ok, results}
    end
  end

  # ============================================================================
  # Event Discovery
  # ============================================================================

  defp discover_previewable_events(otp_app) do
    alias AshDispatch.EventResolver

    # Get all events from introspection
    events = AshDispatch.Introspection.all_events(otp_app)

    # Merge: DSL events take precedence, but fill in modules from registry
    events_with_modules =
      Enum.map(events, fn event ->
        if event.module do
          event
        else
          # Try to find module in registry using EventResolver
          case EventResolver.find_module(event.event_id) do
            {:ok, module} -> Map.put(event, :module, module)
            {:error, :not_found} -> event
          end
        end
      end)

    # Filter to events that have modules with sample_data
    events_with_modules
    |> Enum.filter(fn event ->
      module = event.module
      # Use EventResolver.exports? for safe check
      module != nil && EventResolver.exports?(module, :sample_data, 0)
    end)
    |> Enum.sort_by(& &1.event_id)
  end

  # ============================================================================
  # Preview Generation
  # ============================================================================

  defp generate_all_previews(events, output_dir, otp_app, opts) do
    Enum.map(events, fn event ->
      generate_event_preview(event, output_dir, otp_app, opts)
    end)
  end

  defp generate_event_preview(event, output_dir, otp_app, opts) do
    module = event.module
    event_id = event.event_id
    event_dir = Path.join(output_dir, safe_filename(event_id))

    # Ensure directory exists
    File.mkdir_p!(event_dir)

    # Get sample data from module
    sample_data = module.sample_data()

    # Build context with sample data
    context = build_preview_context(event, sample_data, otp_app)

    # Get channels - DSL channels take precedence, fall back to module callback
    channels = get_preview_channels(event, module, context)

    # Generate previews for each email channel
    files =
      channels
      |> Enum.filter(&(&1.transport == :email))
      |> Enum.flat_map(fn channel ->
        generate_channel_preview(event, module, context, channel, event_dir, otp_app, opts)
      end)

    # Generate metadata.json
    metadata_file = generate_metadata(event, module, context, channels, event_dir)

    if opts[:verbose] do
      Mix.shell().info("  Generated #{length(files) + 1} files for #{event_id}")
    end

    %{
      event_id: event_id,
      event_dir: event_dir,
      files: files ++ [metadata_file],
      success: true
    }
  rescue
    error ->
      Mix.shell().error("Failed to generate preview for #{event.event_id}: #{inspect(error)}")

      %{
        event_id: event.event_id,
        event_dir: Path.join(output_dir, safe_filename(event.event_id)),
        files: [],
        success: false,
        error: error
      }
  end

  defp generate_channel_preview(event, module, context, channel, event_dir, otp_app, opts) do
    alias AshDispatch.EventResolver

    audience = channel.audience

    # Use EventResolver for safe callback execution with defaults
    variant = channel.variant || EventResolver.template_variant(module, context, channel)

    # Get subject and from for this channel using EventResolver
    subject = EventResolver.subject(module, context, channel) || "Preview Subject"

    from_result = EventResolver.from(module, context, channel)
    {from_name, from_email} = from_result || {"Preview", "preview@example.com"}

    # Prepare template assigns using EventResolver
    base_assigns = EventResolver.prepare_template_assigns(module, context, channel)

    assigns =
      context.data
      |> Map.merge(base_assigns)
      |> Map.put(:subject, subject)

    files = []

    # Generate HTML preview
    html_result =
      AshDispatch.TemplateResolver.render(
        event_module: module,
        format: :html,
        transport: :email,
        variant: variant,
        assigns: assigns,
        otp_app: otp_app
      )

    files =
      case html_result do
        {:ok, html_content} ->
          # Wrap in preview shell with metadata (now includes audience)
          wrapped_html =
            wrap_html_preview(html_content, subject, from_name, from_email, event, audience)

          filename = AshDispatch.Naming.filename("email", audience, variant, "html")
          path = Path.join(event_dir, filename)
          File.write!(path, wrapped_html)

          if opts[:verbose] do
            Mix.shell().info([:green, "    * creating ", :reset, path])
          end

          files ++
            [
              %{
                path: path,
                format: :html,
                variant: variant,
                audience: audience,
                transport: channel.transport
              }
            ]

        {:error, reason} ->
          if opts[:verbose] do
            Mix.shell().info([:yellow, "    * skipped HTML: ", :reset, inspect(reason)])
          end

          files
      end

    # Generate text preview
    text_result =
      AshDispatch.TemplateResolver.render(
        event_module: module,
        format: :text,
        transport: :email,
        variant: variant,
        assigns: assigns,
        otp_app: otp_app
      )

    files =
      case text_result do
        {:ok, text_content} ->
          filename = AshDispatch.Naming.filename("email", audience, variant, "txt")
          path = Path.join(event_dir, filename)
          File.write!(path, text_content)

          if opts[:verbose] do
            Mix.shell().info([:green, "    * creating ", :reset, path])
          end

          files ++
            [
              %{
                path: path,
                format: :text,
                variant: variant,
                audience: audience,
                transport: channel.transport
              }
            ]

        {:error, reason} ->
          if opts[:verbose] do
            Mix.shell().info([:yellow, "    * skipped text: ", :reset, inspect(reason)])
          end

          files
      end

    files
  end

  defp generate_metadata(event, module, context, channels, event_dir) do
    email_channels = Enum.filter(channels, &(&1.transport == :email))

    # Get metadata for first email channel (or build default)
    channel =
      List.first(email_channels) || %AshDispatch.Channel{transport: :email, audience: :user}

    subject = module.subject(context, channel)
    {from_name, from_email} = module.from(context, channel)

    metadata = %{
      event_id: event.event_id,
      domain: event.domain,
      resource: event.resource && inspect(event.resource),
      module: inspect(module),
      subject: subject,
      from: %{name: from_name, email: from_email},
      channels:
        Enum.map(channels, fn ch ->
          %{
            transport: ch.transport,
            audience: ch.audience,
            variant: ch.variant
          }
        end),
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    path = Path.join(event_dir, "metadata.json")
    File.write!(path, Jason.encode!(metadata, pretty: true))

    %{path: path, format: :json, variant: nil}
  end

  # ============================================================================
  # Index Generation
  # ============================================================================

  defp generate_index(events, results, output_dir, otp_app) do
    successful_results = Enum.filter(results, & &1.success)

    app_name = otp_app |> to_string() |> Macro.camelize()

    html = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>#{app_name} - Email Template Previews</title>
      <style>
        * { box-sizing: border-box; }
        body {
          font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
          max-width: 1200px;
          margin: 0 auto;
          padding: 40px 20px;
          background: #f5f5f5;
          color: #333;
        }
        h1 {
          color: #1a1a1a;
          border-bottom: 2px solid #e0e0e0;
          padding-bottom: 16px;
          margin-bottom: 32px;
        }
        .stats {
          background: white;
          padding: 16px 24px;
          border-radius: 8px;
          margin-bottom: 32px;
          box-shadow: 0 1px 3px rgba(0,0,0,0.1);
        }
        .stats span {
          margin-right: 24px;
          color: #666;
        }
        .stats strong { color: #333; }
        .events {
          display: grid;
          grid-template-columns: repeat(auto-fill, minmax(350px, 1fr));
          gap: 20px;
        }
        .event-card {
          background: white;
          border-radius: 8px;
          padding: 20px;
          box-shadow: 0 1px 3px rgba(0,0,0,0.1);
          transition: box-shadow 0.2s;
        }
        .event-card:hover {
          box-shadow: 0 4px 12px rgba(0,0,0,0.15);
        }
        .event-card h3 {
          margin: 0 0 8px 0;
          font-size: 16px;
          color: #1a1a1a;
        }
        .event-card .domain {
          font-size: 12px;
          color: #888;
          text-transform: uppercase;
          letter-spacing: 0.5px;
          margin-bottom: 12px;
        }
        .event-card .subject {
          font-size: 14px;
          color: #555;
          margin-bottom: 16px;
          padding: 8px 12px;
          background: #f8f8f8;
          border-radius: 4px;
        }
        .event-card .links {
          display: flex;
          gap: 12px;
          flex-wrap: wrap;
          align-items: center;
        }
        .event-card .channel-group {
          display: inline-flex;
          align-items: center;
          background: #2563eb;
          border-radius: 4px;
          overflow: hidden;
        }
        .event-card .channel-group.variant {
          background: #7c3aed;
        }
        .event-card .channel-group a.primary {
          padding: 6px 10px;
          color: white;
          text-decoration: none;
          font-size: 13px;
        }
        .event-card .channel-group a.primary:hover {
          background: rgba(0,0,0,0.1);
        }
        .event-card .channel-group a.secondary {
          padding: 6px 8px;
          color: rgba(255,255,255,0.8);
          text-decoration: none;
          font-size: 11px;
          background: rgba(0,0,0,0.15);
          border-left: 1px solid rgba(255,255,255,0.2);
        }
        .event-card .channel-group a.secondary:hover {
          background: rgba(0,0,0,0.25);
          color: white;
        }
        .event-card .links a.meta-link {
          padding: 6px 10px;
          background: #e5e7eb;
          color: #6b7280;
          text-decoration: none;
          border-radius: 4px;
          font-size: 12px;
        }
        .event-card .links a.meta-link:hover {
          background: #d1d5db;
          color: #374151;
        }
        .generated-at {
          margin-top: 40px;
          text-align: center;
          color: #888;
          font-size: 13px;
        }
      </style>
    </head>
    <body>
      <h1>📧 #{app_name} Email Templates</h1>

      <div class="stats">
        <span><strong>#{length(successful_results)}</strong> events</span>
        <span><strong>#{count_files(results)}</strong> files generated</span>
      </div>

      <div class="events">
        #{Enum.map_join(successful_results, "\n", &render_event_card(&1, events))}
      </div>

      <p class="generated-at">
        Generated by <code>mix ash_dispatch.gen.previews</code> at #{DateTime.utc_now() |> DateTime.to_iso8601()}
      </p>
    </body>
    </html>
    """

    path = Path.join(output_dir, "index.html")
    File.write!(path, html)
    Mix.shell().info([:green, "* creating ", :reset, path])
  end

  defp render_event_card(result, events) do
    event = Enum.find(events, &(&1.event_id == result.event_id))
    event_dir = safe_filename(result.event_id)

    # Read metadata if available
    metadata_path = Path.join(result.event_dir, "metadata.json")

    subject =
      if File.exists?(metadata_path) do
        case Jason.decode(File.read!(metadata_path)) do
          {:ok, meta} -> meta["subject"] || "No subject"
          _ -> "No subject"
        end
      else
        "No subject"
      end

    # Group template files by audience+variant, then show HTML/text together
    template_files = Enum.filter(result.files, &(&1.format in [:html, :text]))

    grouped =
      template_files
      |> Enum.group_by(fn file -> {file[:transport], file[:audience], file[:variant]} end)

    channel_links =
      grouped
      |> Enum.sort_by(fn {{_transport, audience, _variant}, _files} ->
        # Sort user first, then admin, then others
        case audience do
          :user -> 0
          :admin -> 1
          _ -> 2
        end
      end)
      |> Enum.map(fn {{transport, audience, variant}, files} ->
        html_file = Enum.find(files, &(&1.format == :html))
        text_file = Enum.find(files, &(&1.format == :text))

        label = AshDispatch.Naming.label(transport, audience, variant)
        # Use variant styling if has meaningful variant or is admin audience
        class =
          if AshDispatch.Naming.include_variant?(audience, variant) || audience == :admin do
            "channel-group variant"
          else
            "channel-group"
          end

        html_link =
          if html_file do
            filename = Path.basename(html_file.path)
            ~s(<a href="#{event_dir}/#{filename}" class="primary">#{label}</a>)
          else
            ""
          end

        text_link =
          if text_file do
            filename = Path.basename(text_file.path)
            ~s(<a href="#{event_dir}/#{filename}" class="secondary">text</a>)
          else
            ""
          end

        ~s(<span class="#{class}">#{html_link}#{text_link}</span>)
      end)
      |> Enum.join("")

    """
    <div class="event-card">
      <div class="domain">#{event.domain || "unknown"}</div>
      <h3>#{result.event_id}</h3>
      <div class="subject">#{escape_html(subject)}</div>
      <div class="links">
        #{channel_links}
        <a href="#{event_dir}/metadata.json" class="meta-link">JSON</a>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Check Mode
  # ============================================================================

  defp check_previews_up_to_date(results, output_dir) do
    failed = Enum.filter(results, &(!&1.success))

    if length(failed) > 0 do
      Mix.shell().error("\nPreview generation failed for #{length(failed)} event(s):")

      Enum.each(failed, fn result ->
        Mix.shell().error("  - #{result.event_id}: #{inspect(result.error)}")
      end)

      exit({:shutdown, 1})
    end

    # Check if index exists
    index_path = Path.join(output_dir, "index.html")

    unless File.exists?(index_path) do
      Mix.shell().error("\nIndex file missing: #{index_path}")
      exit({:shutdown, 1})
    end

    :ok
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp default_output_dir(_otp_app) do
    # Output to project's priv directory (not _build)
    Path.join(["priv", "ash_dispatch", "previews"])
  end

  defp build_preview_context(event, sample_data, _otp_app) do
    %AshDispatch.Context{
      event_id: event.event_id,
      data: sample_data,
      variables: %{},
      metadata: %{},
      resource_key: event[:data_key] || :record
    }
  end

  defp get_preview_channels(event, module, context) do
    # Use centralized ChannelResolver for consistent priority logic
    AshDispatch.ChannelResolver.resolve(
      event.event_id,
      module,
      context,
      dsl_channels: event[:channels]
    )
  end

  defp safe_filename(event_id) do
    String.replace(event_id, ~r/[^a-zA-Z0-9_.-]/, "_")
  end

  defp count_files(results) do
    results
    |> Enum.filter(& &1.success)
    |> Enum.map(&length(&1.files))
    |> Enum.sum()
  end

  defp wrap_html_preview(content, subject, from_name, from_email, event, audience) do
    audience_badge =
      if audience do
        ~s(<span class="audience-badge">#{audience}</span>)
      else
        ""
      end

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>#{escape_html(subject)}</title>
      <style>
        body {
          font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
          margin: 0;
          padding: 0;
          background: #f0f0f0;
        }
        .preview-header {
          background: #1a1a1a;
          color: white;
          padding: 16px 24px;
          font-size: 14px;
        }
        .preview-header .meta {
          display: flex;
          gap: 24px;
          flex-wrap: wrap;
        }
        .preview-header .meta-item {
          display: flex;
          gap: 8px;
        }
        .preview-header .label {
          color: #888;
        }
        .preview-header .value {
          color: #fff;
        }
        .preview-header .event-id {
          background: #333;
          padding: 4px 8px;
          border-radius: 4px;
          font-family: monospace;
          font-size: 12px;
        }
        .preview-header .audience-badge {
          background: #2563eb;
          padding: 4px 8px;
          border-radius: 4px;
          font-size: 12px;
          text-transform: uppercase;
          letter-spacing: 0.5px;
        }
        .preview-content {
          background: white;
          max-width: 800px;
          margin: 24px auto;
          box-shadow: 0 2px 8px rgba(0,0,0,0.1);
        }
        .back-link {
          display: inline-block;
          margin: 16px 24px;
          color: #2563eb;
          text-decoration: none;
          font-size: 14px;
        }
        .back-link:hover {
          text-decoration: underline;
        }
      </style>
    </head>
    <body>
      <div class="preview-header">
        <div class="meta">
          <div class="meta-item">
            <span class="label">Event:</span>
            <span class="event-id">#{event.event_id}</span>
          </div>
          <div class="meta-item">
            <span class="label">Audience:</span>
            #{audience_badge}
          </div>
          <div class="meta-item">
            <span class="label">Subject:</span>
            <span class="value">#{escape_html(subject)}</span>
          </div>
          <div class="meta-item">
            <span class="label">From:</span>
            <span class="value">#{escape_html(from_name)} &lt;#{escape_html(from_email)}&gt;</span>
          </div>
        </div>
      </div>
      <a href="../index.html" class="back-link">← Back to all templates</a>
      <div class="preview-content">
        #{content}
      </div>
    </body>
    </html>
    """
  end

  defp escape_html(nil), do: ""

  defp escape_html(string) when is_binary(string) do
    string
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp escape_html(other), do: escape_html(to_string(other))
end
