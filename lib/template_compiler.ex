defmodule AshDispatch.TemplateCompiler do
  @moduledoc """
  Compiles templates at build-time for production releases.

  Use this macro in your event modules to embed templates in the BEAM file.

  ## Usage

      defmodule MyApp.Events.Orders.Created do
        use AshDispatch.Event
        require AshDispatch.TemplateCompiler

        # Compile all templates in ./templates/ directory
        AshDispatch.TemplateCompiler.compile_templates()

        # ... rest of event module ...
      end

  This will:
  1. Scan `./templates/` directory (relative to module file)
  2. Read all `.heex` and `.eex` files
  3. Embed them as module attributes
  4. Export via `__compiled_templates__/0` function
  5. Mark files as external resources (recompile on change)

  ## Production Benefits

  - No runtime file I/O
  - Templates bundled in release
  - Faster template loading
  - No filesystem dependencies

  ## Development Mode

  In development, templates are loaded from files (via `TemplateResolver`),
  so you can edit them without recompiling.
  """

  @doc """
  Compiles all templates in the `templates/` directory next to the calling module.

  ## Example Directory Structure

      lib/my_app/events/orders/created/
      ├── event.ex                    # Event module
      └── templates/
          ├── email.html.heex         # Default HTML email
          ├── email.text.eex          # Default text email
          ├── email.admin.html.heex   # Admin-specific HTML
          └── email.admin.text.eex    # Admin-specific text

  ## Generated Function

  Creates a `__compiled_templates__/0` function that returns:

      %{
        "email.html.heex" => "<html>...</html>",
        "email.text.eex" => "Plain text...",
        "email.admin.html.heex" => "<html>Admin version...</html>",
        "email.admin.text.eex" => "Admin text..."
      }
  """
  defmacro compile_templates do
    quote do
      # Get the directory of the calling module
      module_dir = __DIR__

      # Look for templates/ subdirectory
      templates_dir = Path.join(module_dir, "templates")

      # Find all template files
      template_files =
        if File.dir?(templates_dir) do
          templates_dir
          |> File.ls!()
          |> Enum.filter(&String.match?(&1, ~r/\.(heex|eex)$/))
          |> Enum.sort()
        else
          []
        end

      # Read and store each template
      templates =
        for filename <- template_files do
          path = Path.join(templates_dir, filename)
          content = File.read!(path)

          # Mark as external resource so module recompiles when template changes
          @external_resource path

          {filename, content}
        end

      # Store as module attribute
      @compiled_templates Map.new(templates)

      # Export function to access compiled templates
      @doc false
      def __compiled_templates__, do: @compiled_templates
    end
  end

  @doc """
  Lists all compiled template filenames.

  Returns empty list if templates haven't been compiled.
  """
  def list_templates(module) do
    if function_exported?(module, :__compiled_templates__, 0) do
      module.__compiled_templates__()
      |> Map.keys()
      |> Enum.sort()
    else
      []
    end
  end

  @doc """
  Gets a specific compiled template by filename.

  Returns `{:ok, content}` or `:error`.
  """
  def get_template(module, filename) do
    if function_exported?(module, :__compiled_templates__, 0) do
      case Map.fetch(module.__compiled_templates__(), filename) do
        {:ok, content} -> {:ok, content}
        :error -> :error
      end
    else
      :error
    end
  end
end
