defmodule Mix.Tasks.AshDispatch.Gen.Event do
  @shortdoc "Generates inline dispatch DSL and content-only templates for a new event"

  @moduledoc """
  Generates inline dispatch DSL code and email templates for a new event.

  Templates are content-only - they'll be wrapped in your layouts automatically.

  ## Usage

      mix ash_dispatch.gen.event RESOURCE EVENT [options]

  ## Arguments

    * `RESOURCE` - The resource name (e.g., "order", "ticket", "reseller_request")
    * `EVENT` - The event name (e.g., "created", "cancelled", "accepted")

  ## Options

    * `--subject` - Email subject line (required)
    * `--trigger` - Action that triggers this event (default: EVENT name)
    * `--audience` - Target audience: user, admin, or both (default: "user")
    * `--channels` - Comma-separated: in_app,email (default: "in_app,email")
    * `--title` - In-app notification title
    * `--message` - In-app notification message

  ## Examples

      # Simple user-facing event
      mix ash_dispatch.gen.event order created \\
        --subject "Din order har skapats" \\
        --title "Order skapad" \\
        --message "Order {{order_number}} har registrerats"

      # Admin notification
      mix ash_dispatch.gen.event ticket created \\
        --subject "Nytt supportärende" \\
        --audience both \\
        --title "Nytt ärende" \\
        --message "Ärende från {{user_email}}"

  ## Output

  The task:
  1. Creates content-only templates in `priv/ash_dispatch/templates/{resource}/{event}/`
  2. Prints inline DSL code to paste into your resource's `dispatch do` block

  Templates only contain event-specific content - they're wrapped in your
  `priv/ash_dispatch/layouts/` at render time.
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, args, _} =
      OptionParser.parse(args,
        strict: [
          subject: :string,
          trigger: :string,
          audience: :string,
          channels: :string,
          title: :string,
          message: :string
        ]
      )

    case args do
      [resource, event] ->
        generate_event(resource, event, opts)

      _ ->
        Mix.shell().error("""
        Invalid arguments. Expected:

            mix ash_dispatch.gen.event RESOURCE EVENT [options]

        Examples:

            mix ash_dispatch.gen.event order created --subject "Order skapad"
            mix ash_dispatch.gen.event ticket resolved --subject "Ärende löst" --audience both

        Run `mix help ash_dispatch.gen.event` for more information.
        """)

        exit({:shutdown, 1})
    end
  end

  defp generate_event(resource, event, opts) do
    # Validate and prepare options
    subject = opts[:subject] || prompt_for("Email subject")
    trigger = opts[:trigger] || event
    audience = parse_audience(opts[:audience] || "user")
    channels = parse_channels(opts[:channels] || "in_app,email")
    title = opts[:title] || "TODO: Notification title"
    message = opts[:message] || "TODO: Notification message"

    # Calculate paths
    templates_dir = Path.join(["priv", "ash_dispatch", "templates", resource, event])

    # Create template directory
    File.mkdir_p!(templates_dir)

    # Generate content-only templates
    generate_templates(templates_dir, audience)

    # Generate and print inline DSL
    dsl_code = generate_inline_dsl(resource, event, trigger, audience, channels, subject, title, message)

    Mix.shell().info("""

    #{IO.ANSI.green()}✓ Event templates generated!#{IO.ANSI.reset()}

    Templates created in: #{templates_dir}/

    #{IO.ANSI.cyan()}Add this to your resource's dispatch block:#{IO.ANSI.reset()}

    #{dsl_code}
    """)
  end

  defp prompt_for(field) do
    value = Mix.shell().prompt("#{field}:") |> String.trim()

    if value == "" do
      Mix.shell().error("#{field} is required!")
      exit({:shutdown, 1})
    end

    value
  end

  defp parse_audience("user"), do: [:user]
  defp parse_audience("admin"), do: [:admin]
  defp parse_audience("both"), do: [:user, :admin]
  defp parse_audience(_), do: [:user]

  defp parse_channels(channels_str) do
    channels_str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_atom/1)
    |> Enum.filter(&(&1 in [:in_app, :email, :discord, :sms]))
  end

  defp generate_inline_dsl(resource, event, trigger, audiences, channels, subject, title, message) do
    event_atom = String.to_atom(event)
    trigger_atom = String.to_atom(trigger)
    data_key = String.to_atom(resource)

    channel_configs = generate_channel_configs(audiences, channels, subject, title, message)

    """
        event :#{event_atom},
          trigger_on: :#{trigger_atom},
          data_key: :#{data_key},
          channels: [
    #{channel_configs}
          ]
    """
  end

  defp generate_channel_configs(audiences, channels, subject, title, message) do
    configs =
      for audience <- audiences, transport <- channels do
        generate_single_channel(transport, audience, subject, title, message)
      end

    configs
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.join(",\n")
  end

  defp generate_single_channel(:in_app, audience, _subject, title, message) do
    variant = if audience == :admin, do: "\n          variant: :admin,", else: ""

    """
            [
              transport: :in_app,
              audience: :#{audience},#{variant}
              content: [
                title: "#{title}",
                message: "#{message}",
                action_label: "Visa detaljer"
              ],
              metadata: [
                notification_type: :info,
                action_required: #{audience == :admin}
              ]
            ]
    """
  end

  defp generate_single_channel(:email, audience, subject, _title, _message) do
    variant = if audience == :admin, do: "\n          variant: :admin,", else: ""
    from = if audience == :admin, do: "system@example.com", else: "noreply@example.com"

    """
            [
              transport: :email,
              audience: :#{audience},#{variant}
              content: [
                subject: "#{subject}",
                from_email: "#{from}"
              ]
            ]
    """
  end

  defp generate_single_channel(transport, audience, _subject, _title, _message) do
    """
            [
              transport: :#{transport},
              audience: :#{audience}
            ]
    """
  end

  defp generate_templates(templates_dir, audiences) do
    # Generate default template (content-only)
    generate_content_template(templates_dir, "email.html.heex", "user")
    generate_text_content_template(templates_dir, "email.text.eex", "user")

    # Generate admin variant if needed
    if :admin in audiences do
      generate_content_template(templates_dir, "email.admin.html.heex", "admin")
      generate_text_content_template(templates_dir, "email.admin.text.eex", "admin")
    end
  end

  defp generate_content_template(templates_dir, filename, audience) do
    file_path = Path.join(templates_dir, filename)

    content = """
    <p style="margin: 0 0 20px 0; font-size: 16px; line-height: 1.6; color: #374151;">
      Hej<%= if assigns[:display_name], do: " <strong>\#{\@display_name}</strong>", else: "" %>,
    </p>

    <p style="margin: 0 0 20px 0; font-size: 16px; line-height: 1.6; color: #374151;">
      TODO: Add your #{audience} email content here.
    </p>

    <!-- Example: Order details box -->
    <!--
    <div style="background-color: #f0f9ff; border-left: 4px solid #2563eb; padding: 20px; margin: 25px 0; border-radius: 4px;">
      <h2 style="margin: 0 0 15px 0; font-size: 18px; color: #1e40af;">
        Detaljer
      </h2>
      <table width="100%" cellpadding="0" cellspacing="0">
        <tr>
          <td style="padding: 5px 0; color: #6b7280; font-size: 14px;">Ordernummer:</td>
          <td style="padding: 5px 0; color: #374151; font-size: 14px; font-weight: 600; text-align: right;">
            {@order_number}
          </td>
        </tr>
      </table>
    </div>
    -->

    <!-- Example: CTA Button -->
    <!--
    <table width="100%" cellpadding="0" cellspacing="0" style="margin: 30px 0;">
      <tr>
        <td align="center">
          <a href={@action_url} class="button" style="display: inline-block; background: linear-gradient(135deg, #2563eb 0%, #1d4ed8 100%); color: #ffffff; padding: 16px 40px; text-decoration: none; border-radius: 6px; font-weight: 600; font-size: 16px;">
            Visa detaljer →
          </a>
        </td>
      </tr>
    </table>
    -->
    """

    File.write!(file_path, content)
    Mix.shell().info([:green, "* creating ", :reset, file_path])
  end

  defp generate_text_content_template(templates_dir, filename, audience) do
    file_path = Path.join(templates_dir, filename)

    content = """
    Hej<%= if assigns[:display_name], do: " \#{\@display_name}", else: "" %>!

    TODO: Add your #{audience} plain text content here.
    """

    File.write!(file_path, content)
    Mix.shell().info([:green, "* creating ", :reset, file_path])
  end
end
