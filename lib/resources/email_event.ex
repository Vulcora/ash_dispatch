defmodule AshDispatch.Resources.EmailEvent do
  @moduledoc """
  Read-only Ash resource exposing email event metadata via RPC.

  This resource provides structured access to all email events in the system without
  requiring a database table. It reads from the `:ash_dispatch` `:event_modules` config.

  ## Features

  - Lists all registered email events with metadata
  - Provides template previews (HTML/text) in development
  - Exposes channel configuration (subject, timing, audience)
  - Shows event metadata (domain, category, user preferences)

  ## Usage

  Add this resource to your domain and configure RPC + authorization:

      defmodule MyApp.Emails do
        use Ash.Domain,
          extensions: [AshTypescript.Rpc]

        typescript_rpc do
          resource AshDispatch.Resources.EmailEvent do
            rpc_action :list_email_events, :list
            rpc_action :get_email_event, :get
          end
        end

        resources do
          resource AshDispatch.Resources.EmailEvent do
            define :list_email_events, action: :list
            define :get_email_event, action: :get, args: [:id], get?: true
          end
        end
      end

  **Note:** Add authorization policies in your app's domain configuration.
  """

  use Ash.Resource,
    domain: AshDispatch.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshTypescript.Resource]

  typescript do
    type_name("EmailEvent")
  end

  ets do
    private? true
  end

  policies do
    # Admin users can read all events
    policy actor_attribute_equals(:super_admin, true) do
      authorize_if always()
    end

    # Default deny for non-admins
    policy always() do
      forbid_if always()
    end
  end

  attributes do
    attribute :id, :string do
      public? true
      allow_nil? false
      primary_key? true
      description "Event identifier (e.g., 'orders.created')"
    end

    attribute :module, :string do
      public? true
      allow_nil? false
      description "Event module name"
    end

    attribute :domain, :atom do
      public? true
      allow_nil? false
      description "Domain this event belongs to"
    end

    attribute :user_configurable, :boolean do
      public? true
      default false
      description "Whether users can configure delivery preferences"
    end

    attribute :category, :atom do
      public? true
      allow_nil? true
      description "Email preference category"
    end

    attribute :channel_count, :integer do
      public? true
      default 0
      description "Total number of channels for this event"
    end

    attribute :email_channel_count, :integer do
      public? true
      default 0
      description "Number of email channels for this event"
    end

    attribute :channels, {:array, :map} do
      public? true
      default []

      description "List of email channel configurations with subjects, timing, and rendered previews"
    end

    attribute :action_required, :boolean do
      public? true
      default false
      description "Whether this event requires user action"
    end

    attribute :notification_type, :atom do
      public? true
      allow_nil? true
      description "Type of notification (success, info, warning, error)"
    end
  end

  actions do
    read :list do
      primary? true
      description "List all email events"

      manual fn _query, _opts, _context ->
        events =
          list_all_events()
          |> Enum.sort_by(&{&1.domain, &1.id})
          |> Enum.map(&to_ash_struct/1)

        {:ok, events}
      end
    end

    read :get do
      description "Get a specific email event by ID"
      argument :id, :string, allow_nil?: false

      manual fn query, _opts, _context ->
        id = Ash.Query.get_argument(query, :id)
        event = get_event_by_id(id)
        result = if event, do: [to_ash_struct(event)], else: []
        {:ok, result}
      end
    end
  end

  code_interface do
    define :list, action: :list
    define :get, action: :get, args: [:id]
  end

  alias AshDispatch.EventResolver

  # Public helpers for data transformation

  defp list_all_events do
    # Use EventResolver.all_events() for consistent event discovery
    EventResolver.all_events()
    |> Enum.map(fn {event_id, module} ->
      enrich_event(event_id, module)
    end)
    |> Enum.filter(&has_email_channels?/1)
  end

  defp get_event_by_id(id) do
    # Use centralized EventResolver for consistent event lookup
    case EventResolver.find_module(id) do
      {:ok, module} -> enrich_event(id, module)
      {:error, :not_found} -> nil
    end
  end

  defp enrich_event(event_id, event_module) do
    # Build sample context using EventResolver (which internally uses sample_data)
    sample_context = EventResolver.build_sample_context(event_id, event_module)

    # Use centralized ChannelResolver for consistent priority logic
    all_channels = AshDispatch.ChannelResolver.resolve(event_id, event_module, sample_context)

    email_channels =
      all_channels
      |> Enum.filter(&(&1.transport == :email))
      |> Enum.map(&serialize_channel(&1, event_module, sample_context))

    # Use EventResolver for all callback lookups (handles function_exported? and error handling)
    domain = EventResolver.domain(event_module)
    user_configurable = EventResolver.user_configurable?(event_module, sample_context)
    category = EventResolver.category(event_module, sample_context)
    action_required = EventResolver.action_required?(event_module, sample_context)
    notification_type = EventResolver.notification_type(event_module, sample_context)

    %{
      id: event_id,
      module: to_string(event_module),
      domain: domain,
      user_configurable: user_configurable,
      category: category,
      channel_count: length(all_channels),
      email_channel_count: length(email_channels),
      channels: email_channels,
      action_required: action_required,
      notification_type: notification_type
    }
  end

  defp serialize_channel(%AshDispatch.Channel{} = channel, event_module, context) do
    # Use EventResolver for all callback lookups (handles function_exported? and error handling)
    variant = EventResolver.template_variant(event_module, context, channel)
    additional_assigns = EventResolver.prepare_template_assigns(event_module, context, channel)
    subject = EventResolver.subject(event_module, context, channel)

    # Add subject to assigns for template rendering
    assigns_with_subject = Map.merge(additional_assigns, %{subject: subject})
    enhanced_context = %{context | data: Map.merge(context.data, assigns_with_subject)}

    # Render template previews
    # In dev: uses file-based templates from lib/ via event_dir
    # In prod: uses priv manifest (event_dir will be nil, triggering fallback)
    # Wrapped in try/rescue to handle incomplete sample data gracefully
    {html_preview, text_preview} =
      try do
        # Get event_dir from module source location for template resolution
        # In production, this returns nil (source not available), triggering priv manifest fallback
        event_dir = get_event_dir(event_module)
        otp_app = AshDispatch.Config.otp_app()

        html =
          case AshDispatch.TemplateResolver.render(
                 event_module: event_module,
                 event_dir: event_dir,
                 otp_app: otp_app,
                 format: :html,
                 transport: channel.transport,
                 variant: variant,
                 assigns: enhanced_context.data
               ) do
            {:ok, html} -> html
            {:error, _} -> nil
          end

        text =
          case AshDispatch.TemplateResolver.render(
                 event_module: event_module,
                 event_dir: event_dir,
                 otp_app: otp_app,
                 format: :text,
                 transport: channel.transport,
                 variant: variant,
                 assigns: enhanced_context.data
               ) do
            {:ok, text} -> text
            {:error, _} -> nil
          end

        {html, text}
      rescue
        _ -> {nil, nil}
      end

    %{
      transport: channel.transport,
      audience: channel.audience,
      variant: variant,
      subject: subject,
      time: serialize_time(channel.time),
      policy: channel.policy,
      preview_html: html_preview,
      preview_text: text_preview
    }
  end

  defp serialize_time(nil), do: %{type: "immediate"}
  defp serialize_time({:in, seconds}), do: %{type: "delayed", seconds: seconds}

  defp serialize_time({:at, %DateTime{} = dt}),
    do: %{type: "scheduled", datetime: DateTime.to_iso8601(dt)}

  defp serialize_time(_), do: %{type: "unknown"}

  defp has_email_channels?(event), do: Map.get(event, :email_channel_count, 0) > 0

  defp to_ash_struct(map) do
    struct(__MODULE__, map)
    |> Ash.Resource.set_metadata(%{})
  end

  # Get the directory containing the event module's source file
  defp get_event_dir(event_module) do
    case event_module.__info__(:compile)[:source] do
      nil -> nil
      source -> source |> to_string() |> Path.dirname()
    end
  rescue
    _ -> nil
  end
end
