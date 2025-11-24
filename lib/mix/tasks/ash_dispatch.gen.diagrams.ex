defmodule Mix.Tasks.AshDispatch.Gen.Diagrams do
  @moduledoc """
  Generates Mermaid diagrams showing AshDispatch events, channels, and counters.

  Extends Ash's standard resource diagrams with dispatch-specific information:
  - Events triggered by actions
  - Channels with transports and audiences
  - Counter broadcasts
  - Recipient flows

  ## Usage

      # Generate diagrams for all domains
      mix ash_dispatch.gen.diagrams

      # Generate for specific domain
      mix ash_dispatch.gen.diagrams --only MyApp.Accounts

      # Generate as SVG (requires mermaid-cli)
      mix ash_dispatch.gen.diagrams --format svg

  ## Output Formats

  - `plain` (default) - Mermaid syntax in .mmd files
  - `md` - Markdown code blocks
  - `svg` - SVG images (requires mermaid-cli)
  - `png` - PNG images (requires mermaid-cli)

  ## Generated Files

  Creates one diagram per domain in `./dispatch_diagrams/`:
  - `my_app_accounts.mmd` - Mermaid source
  - `my_app_accounts.svg` - (if --format svg)
  """

  use Mix.Task

  @shortdoc "Generate Mermaid diagrams for AshDispatch events and channels"

  @switches [
    only: :string,
    format: :string,
    output_dir: :string
  ]

  @aliases [
    o: :only,
    f: :format,
    d: :output_dir
  ]

  def run(args) do
    Mix.Task.run("compile")
    Mix.Task.reenable("ash_dispatch.gen.diagrams")

    {opts, _} = OptionParser.parse!(args, strict: @switches, aliases: @aliases)

    format = Keyword.get(opts, :format, "plain")
    output_dir = Keyword.get(opts, :output_dir, "dispatch_diagrams")
    only_domain = Keyword.get(opts, :only)

    # Ensure output directory exists
    File.mkdir_p!(output_dir)

    # Get all Ash domains
    domains =
      if only_domain do
        [Module.concat([only_domain])]
      else
        Application.loaded_applications()
        |> Enum.flat_map(fn {app, _, _} ->
          Application.get_env(app, :ash_domains, [])
        end)
        |> Enum.uniq()
      end

    if Enum.empty?(domains) do
      Mix.shell().error(
        "No Ash domains found. Make sure domains are configured in your app config."
      )

      Mix.shell().info("Example: config :my_app, ash_domains: [MyApp.Accounts, MyApp.Orders]")
    else
      Enum.each(domains, fn domain ->
        generate_diagram_for_domain(domain, format, output_dir)
      end)

      Mix.shell().info("✓ Generated diagrams in #{output_dir}/")
    end
  end

  defp generate_diagram_for_domain(domain, format, output_dir) do
    domain_name = domain |> Module.split() |> Enum.join("_") |> Macro.underscore()
    resources = Ash.Domain.Info.resources(domain)

    # Filter resources that have AshDispatch
    dispatch_resources =
      Enum.filter(resources, &AshDispatch.Resource.Info.dispatch_enabled?/1)

    if Enum.empty?(dispatch_resources) do
      Mix.shell().info("Skipping #{inspect(domain)} - no dispatch resources")
      :ok
    else
      mermaid = generate_mermaid(domain, dispatch_resources)
      output_file = Path.join(output_dir, "#{domain_name}.mmd")

      File.write!(output_file, mermaid)
      Mix.shell().info("Generated: #{output_file}")

      # Convert to other formats if requested
      case format do
        "md" ->
          md_content = "```mermaid\n#{mermaid}\n```\n"
          md_file = Path.join(output_dir, "#{domain_name}.md")
          File.write!(md_file, md_content)
          Mix.shell().info("Generated: #{md_file}")

        "svg" ->
          convert_with_mermaid_cli(output_file, "svg")

        "png" ->
          convert_with_mermaid_cli(output_file, "png")

        _ ->
          :ok
      end
    end
  end

  defp generate_mermaid(domain, resources) do
    domain_name = domain |> Module.split() |> List.last()

    lines = [
      "graph TB",
      "    classDef resource fill:#e1f5ff,stroke:#01579b,stroke-width:2px,color:#000",
      "    classDef event fill:#fff3e0,stroke:#e65100,stroke-width:2px,color:#000",
      "    classDef transport fill:#f3e5f5,stroke:#4a148c,stroke-width:2px,color:#000",
      "    classDef counter fill:#e8f5e9,stroke:#1b5e20,stroke-width:2px,color:#000",
      "",
      "    subgraph #{domain_name}",
      ""
    ]

    resource_lines =
      Enum.flat_map(resources, fn resource ->
        generate_resource_nodes(resource)
      end)

    lines = lines ++ resource_lines ++ ["    end", ""]

    # Add legend
    legend = [
      "    subgraph Legend",
      "        R[Resource]:::resource",
      "        E[Event]:::event",
      "        T[Transport]:::transport",
      "        C[Counter]:::counter",
      "    end"
    ]

    (lines ++ legend)
    |> Enum.join("\n")
  end

  defp generate_resource_nodes(resource) do
    resource_name = resource |> Module.split() |> List.last()
    resource_id = node_id(resource_name)

    lines = [
      "        #{resource_id}[#{resource_name}]:::resource"
    ]

    # Add events
    events = AshDispatch.Resource.Info.events(resource)

    event_lines =
      Enum.flat_map(events, fn event ->
        generate_event_nodes(resource_id, resource_name, event)
      end)

    # Add counters
    counters = AshDispatch.Resource.Info.counters(resource)

    counter_lines =
      Enum.flat_map(counters, fn counter ->
        generate_counter_nodes(resource_id, resource_name, counter)
      end)

    lines ++ event_lines ++ counter_lines
  end

  defp generate_event_nodes(resource_id, resource_name, event) do
    event_id = node_id("#{resource_name}_#{event.name}")
    trigger_on = event.trigger_on |> List.wrap() |> Enum.join(", ")

    lines = [
      "        #{event_id}[\"📧 #{event.name}<br/>trigger: #{trigger_on}\"]:::event",
      "        #{resource_id} -->|dispatches| #{event_id}"
    ]

    # Add channels
    channels = event.channels || []

    channel_lines =
      channels
      |> Enum.with_index()
      |> Enum.flat_map(fn {channel_config, idx} ->
        generate_channel_nodes(event_id, event.name, channel_config, idx)
      end)

    lines ++ channel_lines
  end

  defp generate_channel_nodes(event_id, event_name, channel_config, idx) do
    transport = Keyword.get(channel_config, :transport)
    audience = Keyword.get(channel_config, :audience)
    delay = Keyword.get(channel_config, :delay)

    channel_id = node_id("#{event_name}_ch#{idx}")

    delay_text = if delay, do: "<br/>delay: #{delay}s", else: ""
    label = "#{transport}<br/>→ #{audience}#{delay_text}"

    [
      "        #{channel_id}[\"🚀 #{label}\"]:::transport",
      "        #{event_id} -.->|channel| #{channel_id}"
    ]
  end

  defp generate_counter_nodes(resource_id, resource_name, counter) do
    counter_id = node_id("#{resource_name}_#{counter.name}")
    trigger_on = counter.trigger_on |> List.wrap() |> Enum.join(", ")
    counter_name = counter.counter_name || counter.name

    [
      "        #{counter_id}[\"📊 #{counter_name}<br/>trigger: #{trigger_on}<br/>→ #{counter.audience}\"]:::counter",
      "        #{resource_id} ==>|broadcasts| #{counter_id}"
    ]
  end

  defp node_id(name) do
    name
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
  end

  defp convert_with_mermaid_cli(input_file, format) do
    output_file = String.replace(input_file, ".mmd", ".#{format}")

    case System.cmd("mmdc", ["-i", input_file, "-o", output_file], stderr_to_stdout: true) do
      {_, 0} ->
        Mix.shell().info("Generated: #{output_file}")

      {output, _} ->
        Mix.shell().error("Failed to convert to #{format}. Is mermaid-cli installed?")
        Mix.shell().error("Install: npm install -g @mermaid-js/mermaid-cli")
        Mix.shell().info("Error: #{output}")
    end
  rescue
    e in ErlangError ->
      if e.original == :enoent do
        Mix.shell().error(
          "mermaid-cli not found. Install: npm install -g @mermaid-js/mermaid-cli"
        )
      else
        raise e
      end
  end
end
