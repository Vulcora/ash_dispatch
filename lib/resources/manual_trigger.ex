# TypeScript half of the resource, split out because `ash_typescript` is
# optional — see the same fragment in `AshDispatch.Resources.EmailEvent` for
# why it has to be a fragment (#31).
if Code.ensure_loaded?(AshTypescript.Resource) do
  defmodule AshDispatch.Resources.ManualTrigger.Typescript do
    @moduledoc false
    use Spark.Dsl.Fragment, of: Ash.Resource, extensions: [AshTypescript.Resource]

    typescript do
      type_name("ManualTrigger")
    end
  end
else
  defmodule AshDispatch.Resources.ManualTrigger.Typescript do
    @moduledoc false
    use Spark.Dsl.Fragment, of: Ash.Resource
  end
end

defmodule AshDispatch.Resources.ManualTrigger do
  @moduledoc """
  > #### Deprecated — use `AshDispatch.Resources.ManualTrigger.Base` {: .warning}
  >
  > The `.Base` variant is the maintained one:
  > `use AshDispatch.Resources.ManualTrigger.Base, domain: MyApp.Deliveries`.
  > Since 0.8.6 this variant's `:preview` and `:trigger` run through the same
  > helpers as `.Base` (its `:trigger` used to raise). Kept only so existing
  > registrations keep compiling; it will be removed in a later release.

  Non-persisted resource for manually triggering events from admin interfaces.

  This resource provides actions for:
  - Listing available events (with optional user filtering)
  - Checking user preference status for events
  - Previewing event content before sending
  - Manually dispatching events with custom configuration

  ## Configuration

  Configure the user resource, domain, and preference provider in your app's config:

      config :ash_dispatch,
        event_modules: [...],
        user_resource: MyApp.Accounts.User,  # Ash resource for users
        user_domain: MyApp.Accounts,  # Domain that contains the user resource
        preference_provider: MyApp.PreferenceProvider  # Behavior implementation

  ## Usage

  Add to your domain:

      resources do
        resource AshDispatch.Resources.ManualTrigger do
          define :list_manual_trigger_events, action: :list_events
          define :preview_manual_trigger, action: :preview
          define :trigger_manual_event, action: :trigger
        end
      end

  ## TypeScript RPC

      typescript_rpc do
        resource AshDispatch.Resources.ManualTrigger do
          rpc_action :list_manual_trigger_events, :list_events
          rpc_action :preview_manual_trigger, :preview
          rpc_action :trigger_manual_event, :trigger
        end
      end
  """

  use Ash.Resource,
    domain: nil,
    data_layer: Ash.DataLayer.Simple,
    fragments: [AshDispatch.Resources.ManualTrigger.Typescript],
    validate_domain_inclusion?: false

  alias AshDispatch.{Config, Context, EventResolver}

  resource do
    # This resource is used purely for structuring manual action results,
    # not for persistent data storage. Primary key not needed.
    require_primary_key? false
  end

  actions do
    defaults []

    read :list_events do
      description "List all available email events with their metadata, optionally filtered by user state"

      argument :user_id, :string do
        allow_nil? true

        description "Optional user ID to filter events based on user state (e.g., only show confirmation if not confirmed)"
      end

      prepare fn query, _context ->
        user_id = Ash.Query.get_argument(query, :user_id)

        # Load user if provided (using configured Ash resource)
        user = if user_id, do: load_user(user_id), else: nil

        # Get all registered events from AshDispatch config
        events = list_available_events(user)

        # Convert to embedded resource structs
        records =
          Enum.map(events, fn event_data ->
            struct(__MODULE__, event_data)
          end)

        Ash.DataLayer.Simple.set_data(query, records)
      end
    end

    read :get_user_preference do
      description "Get user's email preference status for a specific event"

      argument :user_id, :string do
        allow_nil? false
        description "The user ID to check preferences for"
      end

      argument :event_id, :string do
        allow_nil? false
        description "The event ID to check"
      end

      prepare fn query, _context ->
        user_id = Ash.Query.get_argument(query, :user_id)
        event_id = Ash.Query.get_argument(query, :event_id)

        case get_user_preference_for_event(user_id, event_id) do
          {:ok, preference_data} ->
            # Convert to embedded resource struct
            record =
              struct(__MODULE__, Map.merge(preference_data, %{event_id: event_id}))

            Ash.DataLayer.Simple.set_data(query, [record])

          {:error, reason} ->
            Ash.Query.add_error(query, reason)
        end
      end
    end

    read :preview do
      description "Preview the email content that would be sent"

      argument :event_id, :string do
        allow_nil? false
      end

      argument :context_data, :map do
        default %{}
      end

      argument :recipient_email, :ci_string
      argument :audience, :atom, constraints: [one_of: [:user, :admin]]
      argument :transport, :atom, constraints: [one_of: [:email, :in_app]]

      prepare fn query, context ->
        event_id = Ash.Query.get_argument(query, :event_id)
        context_data = Ash.Query.get_argument(query, :context_data)
        recipient_email = Ash.Query.get_argument(query, :recipient_email)
        audience = Ash.Query.get_argument(query, :audience)
        transport = Ash.Query.get_argument(query, :transport)

        # Build channel filter
        channel_filter =
          %{}
          |> maybe_add_filter(:audience, audience)
          |> maybe_add_filter(:transport, transport)
          |> case do
            empty when map_size(empty) == 0 -> nil
            filter -> filter
          end

        case AshDispatch.Resources.ManualTrigger.Helpers.preview_trigger(
               event_id,
               context_data,
               channel_filter,
               recipient_email,
               context.actor
             ) do
          {:ok, previews} ->
            # Convert to embedded resource structs
            records =
              Enum.map(previews, fn preview_data ->
                merged = Map.merge(preview_data, %{event_id: event_id})
                struct(__MODULE__, merged)
              end)

            Ash.DataLayer.Simple.set_data(query, records)

          {:error, reason} ->
            Ash.Query.add_error(query, reason)
        end
      end
    end

    create :trigger do
      description "Manually trigger an event with custom configuration"

      accept [
        :event_id,
        :recipient_email,
        :audience,
        :transport,
        :context_data,
        :skip_preferences
      ]

      change fn changeset, context ->
        event_id = Ash.Changeset.get_attribute(changeset, :event_id)
        context_data = Ash.Changeset.get_attribute(changeset, :context_data)
        recipient_email = Ash.Changeset.get_attribute(changeset, :recipient_email)
        audience = Ash.Changeset.get_attribute(changeset, :audience)
        transport = Ash.Changeset.get_attribute(changeset, :transport)
        skip_preferences = Ash.Changeset.get_attribute(changeset, :skip_preferences)

        # The same path as the `.Base` variant: the options reach
        # `Dispatcher.dispatch/4` as options (until 0.8.6 they were a keyword
        # list in the variables slot, which raised).
        opts =
          AshDispatch.Resources.ManualTrigger.Helpers.build_trigger_opts(
            recipient_email,
            audience,
            transport,
            skip_preferences,
            context.actor
          )

        case AshDispatch.Resources.ManualTrigger.Helpers.load_and_dispatch(
               event_id,
               context_data,
               opts,
               context.actor
             ) do
          {:ok, _results} ->
            changeset

          {:error, reason} ->
            Ash.Changeset.add_error(changeset, reason)
        end
      end
    end
  end

  attributes do
    attribute :event_id, :string do
      allow_nil? false
      public? true
    end

    attribute :recipient_email, :ci_string do
      public? true
    end

    attribute :audience, :atom do
      public? true
      constraints one_of: [:user, :admin]
    end

    attribute :transport, :atom do
      public? true
      constraints one_of: [:email, :in_app]
    end

    attribute :context_data, :map do
      public? true
      default %{}
    end

    attribute :skip_preferences, :boolean do
      public? true
      default false
    end

    # Read-only attributes for list_events action
    attribute :description, :string do
      public? true
    end

    attribute :channels, {:array, :map} do
      public? true
    end

    attribute :required_context, {:array, :string} do
      public? true
    end

    attribute :example_context, :map do
      public? true
    end

    attribute :domain, :string do
      public? true
    end

    attribute :required_resources, {:array, :map} do
      public? true
      description "Resources required for manual trigger, with optional Ash filters"
    end

    # Preview attributes
    attribute :subject, :string do
      public? true
    end

    attribute :html_body, :string do
      public? true
    end

    attribute :text_body, :string do
      public? true
    end

    attribute :from_address, :string do
      public? true
    end

    attribute :recipient, :string do
      public? true
    end

    # In-app notification preview attributes
    attribute :notification_title, :string do
      public? true
      description "Title for in-app notification preview"
    end

    attribute :notification_message, :string do
      public? true
      description "Message for in-app notification preview"
    end

    # User preference attributes
    attribute :user_configurable, :boolean do
      public? true
    end

    attribute :category, :string do
      public? true
    end

    attribute :preference_enabled, :boolean do
      public? true
    end
  end

  # Private helper functions

  defp load_user(user_id) do
    user_resource = Config.user_resource()
    user_domain = Config.user_domain()

    if user_resource && user_domain do
      case Ash.get(user_resource, user_id, domain: user_domain, authorize?: false) do
        {:ok, user} -> user
        _ -> nil
      end
    else
      nil
    end
  end

  defp list_available_events(user) do
    alias AshDispatch.ChannelResolver

    # Use EventResolver.all_events() for consistent event discovery
    EventResolver.all_events()
    |> Enum.filter(fn {_event_id, event_module} ->
      # Only include events with email channels
      has_email_channels?(event_module) &&
        is_event_applicable_for_user?(event_module, user)
    end)
    |> Enum.map(fn {event_id, event_module} ->
      # Build sample context using EventResolver
      sample_context = EventResolver.build_sample_context(event_id, event_module)

      # Use centralized ChannelResolver for consistent priority logic
      channels = ChannelResolver.resolve(event_id, event_module, sample_context)

      %{
        event_id: event_id,
        description: get_event_description(event_module),
        domain: EventResolver.domain(event_module) |> to_string_or_nil(),
        channels: format_channels(channels),
        required_context: get_required_context(event_id),
        example_context: get_example_context(event_id, event_module),
        required_resources:
          EventResolver.required_resources(event_module) |> format_required_resources()
      }
    end)
    |> Enum.sort_by(& &1.event_id)
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)

  defp has_email_channels?(event_module) do
    # Use EventResolver for safe callback execution
    sample_data = EventResolver.sample_data(event_module)
    event_id = EventResolver.event_id(event_module)
    context = %Context{event_id: event_id || "sample", data: sample_data, metadata: %{}}

    # Use centralized ChannelResolver for consistent priority logic
    AshDispatch.ChannelResolver.has_transport?(event_id, event_module, context, :email)
  end

  defp is_event_applicable_for_user?(_event_module, nil), do: true

  defp is_event_applicable_for_user?(event_module, user) do
    # Use EventResolver for safe callback execution
    EventResolver.applicable_for_user?(event_module, user)
  end

  defp get_user_preference_for_event(user_id, event_id) do
    # Use centralized EventResolver for event lookup
    case EventResolver.find_module(event_id) do
      {:ok, event_module} ->
        # Build sample context using EventResolver
        sample_context = EventResolver.build_sample_context(event_id, event_module)

        # Use EventResolver for safe callback execution
        user_configurable = EventResolver.user_configurable?(event_module, sample_context)

        category =
          if user_configurable do
            EventResolver.category(event_module, sample_context)
          else
            nil
          end

        preference_enabled =
          if user_configurable && category do
            # Use configured preference provider behavior
            preference_provider = Config.preference_provider()

            if preference_provider do
              case preference_provider.get_preferences(user_id) do
                {:ok, prefs} ->
                  preference_provider.preference_enabled?(prefs, category)

                {:error, _} ->
                  true
              end
            else
              true
            end
          else
            nil
          end

        {:ok,
         %{
           user_configurable: user_configurable,
           category: category,
           preference_enabled: preference_enabled
         }}

      {:error, :not_found} ->
        {:error, "Event not found: #{event_id}"}
    end
  end

  defp get_event_description(event_module) do
    case Module.split(event_module) do
      # Pattern: MyApp.Orders.Events.Created.Event -> Orders > Created
      # Pattern: MyApp.Accounts.Events.EmailConfirmation.Event -> Accounts > EmailConfirmation
      parts when length(parts) >= 5 ->
        # Get domain (e.g., "Orders", "Accounts") and event name (e.g., "Created")
        # Second part is the domain
        domain = Enum.at(parts, 1)
        # Second-to-last is the event name
        event_name = Enum.at(parts, -2)

        # Convert PascalCase to Title Case with spaces
        formatted_event =
          event_name
          |> String.replace(~r/([A-Z])/, " \\1")
          |> String.trim()

        "#{domain} > #{formatted_event}"

      _ ->
        "Email event"
    end
  end

  # Format required_resources from EventResolver output
  defp format_required_resources(required_resources) do
    Enum.map(required_resources, fn
      # Simple format: [order: ProductOrder]
      {key, resource_module} when is_atom(resource_module) ->
        %{
          key: to_string(key),
          resource: inspect(resource_module),
          filter: nil
        }

      # With filter: [order: {ProductOrder, filter: [status: :processed]}]
      {key, {resource_module, opts}} when is_atom(resource_module) ->
        filter = Keyword.get(opts, :filter)

        %{
          key: to_string(key),
          resource: inspect(resource_module),
          filter: if(filter, do: Enum.into(filter, %{}), else: nil)
        }

      # Invalid format, skip
      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp format_channels(channels) do
    Enum.map(channels, fn channel ->
      %{
        transport: channel.transport,
        audience: channel.audience,
        time: format_time(channel.time)
      }
    end)
  end

  defp format_time(nil), do: "immediate"
  defp format_time({:in, seconds}), do: "delayed (#{seconds}s)"
  defp format_time({:at, %DateTime{} = dt}), do: "scheduled (#{DateTime.to_iso8601(dt)})"
  defp format_time(_), do: "unknown"

  defp get_required_context(event_id) do
    # Extract required fields from event_id pattern
    case String.split(event_id, ".") do
      ["orders", _] -> ["order_id"]
      ["tickets", _] -> ["ticket_id"]
      ["requests", _] -> ["request_id"]
      ["accounts", "invited"] -> ["invited_user_id", "invited_by_id"]
      ["accounts", _] -> ["user_id"]
      _ -> []
    end
  end

  defp get_example_context(event_id, event_module) do
    # Use EventResolver for safe sample_data retrieval
    sample_data = EventResolver.sample_data(event_module)
    # If sample_data is empty, use default example context
    if map_size(sample_data) > 0, do: sample_data, else: build_default_example_context(event_id)
  end

  defp build_default_example_context(event_id) do
    case String.split(event_id, ".") do
      ["orders", _] -> %{order_id: "uuid-here"}
      ["tickets", _] -> %{ticket_id: "uuid-here"}
      ["requests", _] -> %{request_id: "uuid-here"}
      ["accounts", "invited"] -> %{invited_user_id: "uuid-here", invited_by_id: "uuid-here"}
      ["accounts", _] -> %{user_id: "uuid-here"}
      _ -> %{}
    end
  end

  defp maybe_add_filter(map, _key, nil), do: map
  defp maybe_add_filter(map, key, value), do: Map.put(map, key, value)
end
