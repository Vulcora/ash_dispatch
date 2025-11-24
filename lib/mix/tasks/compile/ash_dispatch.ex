defmodule Mix.Tasks.Compile.AshDispatch do
  @moduledoc """
  Mix compiler that copies AshDispatch templates to priv/ directory.

  This compiler runs during `mix compile` and scans for templates in two locations:

  1. **Convention-based** (inline DSL events):
     - Path: `lib/{app}/{domain}/templates/{resource}/{event}/`
     - Example: `lib/magasin/requests/templates/reseller_request/new/email.html.heex`

  2. **Module-based** (event modules):
     - Path: `lib/{app}/{domain}/events/{event}/templates/`
     - Example: `lib/magasin/accounts/events/invited/templates/email.html.heex`

  Templates are copied to `priv/ash_dispatch/templates/` with a manifest for lookup.
  Development mode uses file-based template loading for fast iteration.

  ## Usage

  Add to your `mix.exs`:

      def project do
        [
          compilers: Mix.compilers() ++ [:ash_dispatch]
        ]
      end

  The compiler will automatically run during `mix compile` and copy templates
  to the priv directory.
  """

  use Mix.Task.Compiler

  @recursive true
  @manifest "compile.ash_dispatch"

  @doc false
  def run(_args) do
    IO.puts("Compiling AshDispatch templates...")

    # Get OTP app name from mix.exs
    config = Mix.Project.config()
    otp_app = config[:app]

    # Discover all templates
    templates = discover_templates(otp_app)

    IO.puts("  Found #{map_size(templates)} template sets")

    # Copy templates to priv/ and generate manifest
    copy_templates_to_priv(templates, otp_app)

    # Write manifest for incremental compilation
    manifest_path = Path.join(Mix.Project.manifest_path(), @manifest)
    File.mkdir_p!(Path.dirname(manifest_path))
    File.write!(manifest_path, :erlang.term_to_binary(templates))

    {:ok, []}
  end

  @doc false
  def manifests do
    [Path.join(Mix.Project.manifest_path(), @manifest)]
  end

  @doc false
  def clean do
    manifest_path = Path.join(Mix.Project.manifest_path(), @manifest)
    File.rm(manifest_path)

    # Remove priv templates directory
    File.rm_rf("priv/ash_dispatch")

    :ok
  end

  # Discover all templates in the project
  defp discover_templates(otp_app) do
    lib_path = "lib/#{otp_app}"

    # Pattern 1: Convention-based (inline DSL)
    # lib/{app}/{domain}/templates/{resource}/{event}/*.{heex,eex}
    convention_templates = discover_convention_based_templates(lib_path)

    # Pattern 2: Module-based (event modules)
    # lib/{app}/{domain}/events/{event}/templates/*.{heex,eex}
    module_templates = discover_module_based_templates(lib_path)

    # Merge both maps
    Map.merge(convention_templates, module_templates)
  end

  # Discover convention-based templates for inline DSL events
  defp discover_convention_based_templates(lib_path) do
    # Find all template directories: lib/{app}/{domain}/templates/{resource}/{event}/
    template_dirs =
      Path.wildcard("#{lib_path}/*/templates/*/*")
      |> Enum.filter(&File.dir?/1)

    Enum.reduce(template_dirs, %{}, fn dir, acc ->
      # Extract domain, resource, event from path
      # Example: lib/magasin/requests/templates/reseller_request/new
      parts = Path.split(dir)

      case parts do
        [_, _app, _domain, "templates", resource, event] ->
          event_id = "#{resource}.#{event}"
          templates = compile_templates_in_dir(dir)

          if map_size(templates) > 0 do
            Map.put(acc, {:event_id, event_id}, templates)
          else
            acc
          end

        _ ->
          acc
      end
    end)
  end

  # Discover module-based templates in event modules
  defp discover_module_based_templates(lib_path) do
    # Find all event module template directories: lib/{app}/{domain}/events/{event}/templates/
    template_dirs =
      Path.wildcard("#{lib_path}/*/events/*/templates")
      |> Enum.filter(&File.dir?/1)

    Enum.reduce(template_dirs, %{}, fn dir, acc ->
      # Extract module path
      # Example: lib/magasin/accounts/events/invited/templates
      parts = Path.split(dir)

      case parts do
        [_, app, domain, "events", event_name, "templates"] ->
          # Derive module name: Magasin.Accounts.Events.Invited.Event
          module_parts = [
            Macro.camelize(to_string(app)),
            Macro.camelize(domain),
            "Events",
            Macro.camelize(event_name),
            "Event"
          ]

          module_name = Module.concat(module_parts)
          templates = compile_templates_in_dir(dir)

          if map_size(templates) > 0 do
            Map.put(acc, {:module, module_name}, templates)
          else
            acc
          end

        _ ->
          acc
      end
    end)
  end

  # Compile all templates in a directory
  defp compile_templates_in_dir(dir) do
    dir
    |> File.ls!()
    |> Enum.filter(&String.match?(&1, ~r/\.(heex|eex)$/))
    |> Enum.reduce(%{}, fn filename, acc ->
      path = Path.join(dir, filename)
      content = File.read!(path)
      Map.put(acc, filename, {content, path})
    end)
  end

  # Copy templates to priv/ directory and generate manifest
  defp copy_templates_to_priv(templates, _otp_app) do
    priv_path = "priv/ash_dispatch/templates"
    File.mkdir_p!(priv_path)

    # Copy each template and build manifest
    manifest =
      Enum.reduce(templates, %{}, fn {lookup_key, template_map}, acc ->
        # Build filename mapping for this lookup key
        template_files =
          Enum.map(template_map, fn {filename, {content, _source_path}} ->
            # Create unique destination filename
            # event_id: "reseller_request.new.email.html.heex"
            # module: "Elixir.Magasin.Accounts.Events.Invited.Event.email.html.heex"
            dest_filename =
              case lookup_key do
                {:event_id, event_id} -> "#{event_id}.#{filename}"
                {:module, module} -> "#{inspect(module)}.#{filename}"
              end

            dest_path = Path.join(priv_path, dest_filename)
            File.write!(dest_path, content)

            {filename, dest_filename}
          end)
          |> Map.new()

        # Add to manifest with string key for JSON serialization
        manifest_key = format_manifest_key(lookup_key)
        Map.put(acc, manifest_key, template_files)
      end)

    # Write manifest as JSON for easy lookup
    manifest_path = "priv/ash_dispatch/manifest.json"
    File.write!(manifest_path, Jason.encode!(manifest, pretty: true))

    IO.puts("  Copied templates to #{priv_path}")
    IO.puts("  Generated manifest at #{manifest_path}")
  end

  # Format lookup key for manifest (string-based for JSON)
  defp format_manifest_key({:event_id, event_id}), do: "event_id:#{event_id}"
  defp format_manifest_key({:module, module}), do: "module:#{inspect(module)}"
end
