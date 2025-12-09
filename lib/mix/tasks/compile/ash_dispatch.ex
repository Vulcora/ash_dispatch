defmodule Mix.Tasks.Compile.AshDispatch do
  @moduledoc """
  Mix compiler that copies AshDispatch templates to priv/ directory.

  **Disabled by default** for fast development iteration. Templates are loaded
  directly from `lib/` in dev mode.

  **Required for production releases** because `lib/` source files are not
  included in releases - only `priv/` is bundled. Without this, template
  rendering (emails, previews) won't work in production.

  ## Configuration

      # config/dev.exs - disabled (default)
      # Templates load from lib/ for fast iteration

      # config/prod.exs - REQUIRED for releases
      config :ash_dispatch,
        compile_templates: true

  ## What It Does

  When enabled, scans for templates in:

  - `lib/{app}/{domain}/events/{event}/templates/*.{heex,eex}`

  And copies them to:

  - `priv/ash_dispatch/templates/`
  - `priv/ash_dispatch/manifest.json`

  This ensures templates are available at runtime in production releases.

  ## Usage

  Add to your `mix.exs`:

      def project do
        [
          compilers: Mix.compilers() ++ [:ash_dispatch]
        ]
      end

  The compiler runs during `mix compile` but only copies files when
  `compile_templates: true` is configured.
  """

  use Mix.Task.Compiler

  @recursive true
  @manifest "compile.ash_dispatch"

  @doc false
  def run(_args) do
    # Skip template compilation unless explicitly enabled via config
    # Templates are loaded directly from lib/ in dev for fast iteration
    # Set `config :ash_dispatch, compile_templates: true` to enable (e.g., in prod)
    if Application.get_env(:ash_dispatch, :compile_templates, false) do
      run_compile()
    else
      {:ok, []}
    end
  end

  defp run_compile do
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
    # Read the JSON manifest to know exactly what files we generated
    # This is surgical - we only delete what we created, never user files
    json_manifest_path = "priv/ash_dispatch/manifest.json"

    if File.exists?(json_manifest_path) do
      case File.read(json_manifest_path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, manifest} ->
              # Delete only the files we generated (listed in manifest)
              priv_path = "priv/ash_dispatch/templates"

              manifest
              |> Map.values()
              |> Enum.flat_map(&Map.values/1)
              |> Enum.each(fn filename ->
                file_path = Path.join(priv_path, filename)
                File.rm(file_path)
              end)

              # Remove templates dir only if empty
              case File.ls(priv_path) do
                {:ok, []} -> File.rmdir(priv_path)
                _ -> :ok
              end

            {:error, _} ->
              :ok
          end

        {:error, _} ->
          :ok
      end

      # Delete the manifest itself
      File.rm(json_manifest_path)
    end

    # Delete the binary manifest
    manifest_path = Path.join(Mix.Project.manifest_path(), @manifest)
    File.rm(manifest_path)

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
  # Also removes stale templates that no longer exist in source
  defp copy_templates_to_priv(templates, _otp_app) do
    priv_path = "priv/ash_dispatch/templates"
    json_manifest_path = "priv/ash_dispatch/manifest.json"

    File.mkdir_p!(priv_path)

    # Load existing manifest to detect stale files
    old_generated_files =
      if File.exists?(json_manifest_path) do
        case File.read!(json_manifest_path) |> Jason.decode() do
          {:ok, old_manifest} ->
            old_manifest
            |> Map.values()
            |> Enum.flat_map(&Map.values/1)
            |> MapSet.new()

          {:error, _} ->
            MapSet.new()
        end
      else
        MapSet.new()
      end

    # Copy each template and build manifest
    {manifest, new_generated_files} =
      Enum.reduce(templates, {%{}, MapSet.new()}, fn {lookup_key, template_map},
                                                     {acc_manifest, acc_files} ->
        # Build filename mapping for this lookup key
        {template_files, generated} =
          Enum.reduce(template_map, {%{}, acc_files}, fn {filename, {content, _source_path}},
                                                         {files_acc, gen_acc} ->
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

            {Map.put(files_acc, filename, dest_filename), MapSet.put(gen_acc, dest_filename)}
          end)

        # Add to manifest with string key for JSON serialization
        manifest_key = format_manifest_key(lookup_key)
        {Map.put(acc_manifest, manifest_key, template_files), generated}
      end)

    # Remove stale files (were in old manifest but not in current)
    stale_files = MapSet.difference(old_generated_files, new_generated_files)

    Enum.each(stale_files, fn filename ->
      file_path = Path.join(priv_path, filename)

      if File.exists?(file_path) do
        File.rm!(file_path)
        IO.puts("  Removed stale template: #{filename}")
      end
    end)

    # Write manifest as JSON for easy lookup
    File.write!(json_manifest_path, Jason.encode!(manifest, pretty: true))

    IO.puts("  Copied templates to #{priv_path}")
    IO.puts("  Generated manifest at #{json_manifest_path}")
  end

  # Format lookup key for manifest (string-based for JSON)
  defp format_manifest_key({:event_id, event_id}), do: "event_id:#{event_id}"
  defp format_manifest_key({:module, module}), do: "module:#{inspect(module)}"
end
