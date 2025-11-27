defmodule Mix.Tasks.AshDispatch.Setup do
  @shortdoc "Sets up AshDispatch directory structure and layouts"

  @moduledoc """
  Sets up the initial AshDispatch directory structure and generates default layouts.

  ## Usage

      mix ash_dispatch.setup

  ## What It Creates

      priv/ash_dispatch/
      ├── layouts/
      │   ├── email.html.heex    # HTML email layout
      │   └── email.text.eex     # Plain text email layout
      └── templates/             # Your event templates go here

  ## Customization

  After running setup, edit the layouts in `priv/ash_dispatch/layouts/` to match
  your brand (logo, colors, footer contact info, etc.).

  Event templates only need to provide content - they'll be wrapped in these layouts.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    # Guard: prevent running from ash_dispatch library itself
    if Mix.Project.config()[:app] == :ash_dispatch do
      Mix.shell().error("This task cannot be run from the ash_dispatch library itself.")
      Mix.shell().info("Run this task from your consuming application instead.")
      exit({:shutdown, 1})
    end

    # Create directory structure
    layouts_dir = "priv/ash_dispatch/layouts"
    templates_dir = "priv/ash_dispatch/templates"

    File.mkdir_p!(layouts_dir)
    File.mkdir_p!(templates_dir)

    Mix.shell().info("Created directory structure")

    # Generate default layouts
    generate_html_layout(layouts_dir)
    generate_text_layout(layouts_dir)

    Mix.shell().info("""

    #{IO.ANSI.green()}✓ AshDispatch setup complete!#{IO.ANSI.reset()}

    Next steps:
    1. Edit #{layouts_dir}/email.html.heex with your brand styling
    2. Edit #{layouts_dir}/email.text.eex with your brand text
    3. Define events in your resource DSL (dispatch do ... end)
    4. Run: mix ash_dispatch.gen  (or mix ash.codegen)
    """)
  end

  defp generate_html_layout(layouts_dir) do
    path = Path.join(layouts_dir, "email.html.heex")

    if File.exists?(path) do
      Mix.shell().info("  • Skipping #{path} (already exists)")
    else
      content = default_html_layout()
      File.write!(path, content)
      Mix.shell().info([:green, "  • Created ", :reset, path])
    end
  end

  defp generate_text_layout(layouts_dir) do
    path = Path.join(layouts_dir, "email.text.eex")

    if File.exists?(path) do
      Mix.shell().info("  • Skipping #{path} (already exists)")
    else
      content = default_text_layout()
      File.write!(path, content)
      Mix.shell().info([:green, "  • Created ", :reset, path])
    end
  end

  defp default_html_layout do
    ~S"""
    <!DOCTYPE html>
    <html>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        <title><%= @subject %></title>
        <style>
          @media only screen and (max-width: 600px) {
            .button { width: 100% !important; }
          }
        </style>
      </head>
      <body style="margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; background-color: #f3f4f6;">
        <table width="100%" cellpadding="0" cellspacing="0" style="background-color: #f3f4f6; padding: 20px 0;">
          <tr>
            <td align="center">
              <table width="600" cellpadding="0" cellspacing="0" style="background-color: #ffffff; border-radius: 8px; box-shadow: 0 2px 8px rgba(0,0,0,0.1); max-width: 600px;">
                <!-- Header -->
                <tr>
                  <td style="background: linear-gradient(135deg, #2563eb 0%, #7c3aed 100%); padding: 40px 30px; text-align: center; border-radius: 8px 8px 0 0;">
                    <h1 style="margin: 0; color: #ffffff; font-size: 28px; font-weight: 700;">
                      <%= @subject %>
                    </h1>
                  </td>
                </tr>

                <!-- Content -->
                <tr>
                  <td style="padding: 40px 30px;">
                    <%= @inner_content %>
                  </td>
                </tr>

                <!-- Footer -->
                <tr>
                  <td style="background-color: #f9fafb; padding: 25px 30px; text-align: center; border-radius: 0 0 8px 8px; border-top: 1px solid #e5e7eb;">
                    <p style="margin: 0 0 10px 0; font-size: 14px; color: #6b7280;">
                      Your Company Name
                    </p>
                    <p style="margin: 0; font-size: 12px; color: #9ca3af;">
                      <a href="mailto:support@example.com" style="color: #2563eb; text-decoration: none;">
                        support@example.com
                      </a>
                    </p>
                  </td>
                </tr>
              </table>
            </td>
          </tr>
        </table>
      </body>
    </html>
    """
  end

  defp default_text_layout do
    ~S"""
    <%= String.upcase(@subject) %>
    ═══════════════════════════════════════════════════════

    <%= @inner_content %>

    ───────────────────────────────────────────────────────

    Your Company Name
    support@example.com

    ═══════════════════════════════════════════════════════
    """
  end
end
