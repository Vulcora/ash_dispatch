defmodule AshDispatch.Resources.ManualTrigger.Helpers do
  @moduledoc false
  # Helper functions for ManualTrigger resources

  alias AshDispatch.{Config, Context, EventResolver, Naming}

  require Logger

  def list_available_events(user) do
    alias AshDispatch.ChannelResolver

    # Only include DSL events with trigger_on: :manual
    # Standalone event modules are not shown in manual trigger UI
    dsl_events = list_dsl_events()

    dsl_events
    |> Enum.filter(fn {event_id, event_module, event_config} ->
      has_email_channels?(event_id, event_module, event_config) &&
        EventResolver.applicable_for_user?(event_module, user)
    end)
    |> Enum.map(fn {event_id, event_module, event_config} ->
      # Use EventResolver for building sample context
      sample_context = EventResolver.build_sample_context(event_id, event_module)

      # Use centralized ChannelResolver for consistent priority logic
      channels =
        ChannelResolver.resolve(
          event_id,
          event_module,
          sample_context,
          dsl_channels: event_config && event_config.channels
        )

      %{
        event_id: event_id,
        description: get_event_description(event_module, event_id),
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

  @doc """
  Lists ALL events (for template preview purposes).

  Unlike list_available_events/1 which only returns manually triggerable events,
  this function returns all events that have email channels defined, regardless
  of their trigger_on setting. This is useful for admin template preview pages.
  """
  def list_all_events do
    alias AshDispatch.ChannelResolver

    # Include ALL DSL events (not just manual triggers)
    dsl_events = list_all_dsl_events()

    dsl_events
    |> Enum.filter(fn {event_id, event_module, event_config} ->
      has_any_channels?(event_id, event_module, event_config)
    end)
    |> Enum.map(fn {event_id, event_module, event_config} ->
      # Use EventResolver for building sample context
      sample_context = EventResolver.build_sample_context(event_id, event_module)

      # Use centralized ChannelResolver for consistent priority logic
      channels =
        ChannelResolver.resolve(
          event_id,
          event_module,
          sample_context,
          dsl_channels: event_config && event_config.channels
        )

      # Get user_configurable from metadata if available
      user_configurable = get_in(event_config.metadata || [], [:user_configurable])
      category = get_in(event_config.metadata || [], [:category]) |> to_string_or_nil()

      %{
        event_id: event_id,
        description: get_event_description(event_module, event_id),
        domain: event_config.domain |> to_string_or_nil(),
        channels: format_channels(channels),
        required_context: get_required_context(event_id),
        example_context: get_example_context(event_id, event_module),
        required_resources:
          EventResolver.required_resources(event_module) |> format_required_resources(),
        user_configurable: user_configurable,
        category: category
      }
    end)
    |> Enum.sort_by(& &1.event_id)
  end

  # List ALL DSL events (for template preview)
  defp list_all_dsl_events do
    domains = Config.domains()

    Enum.flat_map(domains, fn domain ->
      try do
        domain
        |> Ash.Domain.Info.resources()
        |> Enum.flat_map(fn resource ->
          if AshDispatch.Resource.Info.dispatch_enabled?(resource) do
            resource
            |> AshDispatch.Resource.Info.events()
            |> Enum.map(fn event ->
              {event.event_id, event.module, event}
            end)
          else
            []
          end
        end)
      rescue
        _ -> []
      end
    end)
  end

  # Check if event has any channels (email or in_app)
  defp has_any_channels?(_event_id, _event_module, event_config) do
    channels = event_config && event_config.channels
    is_list(channels) && length(channels) > 0
  end

  defp list_dsl_events do
    domains = Config.domains()

    Enum.flat_map(domains, fn domain ->
      try do
        domain
        |> Ash.Domain.Info.resources()
        |> Enum.flat_map(fn resource ->
          if AshDispatch.Resource.Info.dispatch_enabled?(resource) do
            resource
            |> AshDispatch.Resource.Info.events()
            |> Enum.filter(&manually_triggerable?/1)
            |> Enum.map(fn event ->
              {event.event_id, event.module, event}
            end)
          else
            []
          end
        end)
      rescue
        _ -> []
      end
    end)
  end

  # Only events with trigger_on: :manual should appear in manual trigger UI
  defp manually_triggerable?(%{trigger_on: :manual}), do: true

  defp manually_triggerable?(%{trigger_on: triggers}) when is_list(triggers),
    do: :manual in triggers

  defp manually_triggerable?(_), do: false

  def get_user_preference_for_event(user_id, event_id) do
    # Use centralized EventResolver for event lookup
    case EventResolver.find_module(event_id) do
      {:ok, event_module} ->
        # Use EventResolver for building sample context
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

  def build_channel_filter(audience, transport) do
    %{}
    |> maybe_add_filter(:audience, audience)
    |> maybe_add_filter(:transport, transport)
    |> case do
      empty when map_size(empty) == 0 -> nil
      filter -> filter
    end
  end

  def build_trigger_opts(recipient_email, audience, transport, skip_preferences, actor) do
    opts = %{skip_preferences: skip_preferences, actor: actor}

    opts =
      if recipient_email do
        Map.put(opts, :recipient_email, recipient_email)
      else
        opts
      end

    # Build a single channel filter map from audience and transport
    channel_filter =
      %{}
      |> maybe_add_to_map(:audience, audience)
      |> maybe_add_to_map(:transport, transport)

    if map_size(channel_filter) > 0 do
      Map.put(opts, :channels, [channel_filter])
    else
      opts
    end
  end

  @doc """
  Load resource data and dispatch event.

  This function loads the required resource data (e.g., user) based on the event module's
  resource/0 and data_key/0 callbacks before dispatching the event.
  """
  def load_and_dispatch(event_id, context_data, opts, actor) do
    # Use centralized EventResolver for event lookup
    case EventResolver.find_module(event_id) do
      {:ok, event_module} ->
        # Load the resource data using the same logic as preview
        case build_context_from_data(event_id, event_module, context_data, actor) do
          {:ok, context} ->
            # Generate real variables using EventResolver (handles errors gracefully)
            enhanced_opts_result =
              EventResolver.generate_send_variables(event_module, context, opts)

            # Check if variable generation succeeded
            case enhanced_opts_result do
              {:ok, enhanced_opts} ->
                # Dispatch with the loaded data and enhanced variables
                AshDispatch.Dispatcher.dispatch(event_id, context.data, enhanced_opts)

              {:error, reason} ->
                {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :not_found} ->
        {:error, "Event #{event_id} not found"}
    end
  end

  def preview_trigger(event_id, context_data, channel_filter, recipient_email, actor) do
    # Use centralized EventResolver for event lookup
    case EventResolver.find_module(event_id) do
      {:ok, event_module} ->
        with {:ok, context} <-
               build_context_from_data(event_id, event_module, context_data, actor),
             {:ok, channels} <- get_filtered_channels(event_module, context, channel_filter) do
          previews =
            Enum.map(channels, fn channel ->
              # Use EventResolver for all callback lookups
              subject = EventResolver.subject(event_module, context, channel)
              from_result = EventResolver.from(event_module, context, channel)
              from_address = if from_result, do: elem(from_result, 1), else: ""
              recipient = recipient_email || get_preview_recipient(event_module, context, channel)
              # Prefer channel.variant (from DSL) over EventResolver callback
              variant =
                channel.variant || EventResolver.template_variant(event_module, context, channel)

              # Prepare template assigns using EventResolver (with special error handling for previews)
              assigns_result =
                if EventResolver.exports?(event_module, :prepare_template_assigns, 2) do
                  try do
                    base_assigns =
                      EventResolver.prepare_template_assigns(event_module, context, channel)

                    {:ok, Map.merge(context.data, base_assigns)}
                  rescue
                    e ->
                      Logger.error("prepare_template_assigns failed: #{inspect(e)}")
                      Logger.error("Context data: #{inspect(context.data)}")

                      {:error,
                       "prepare_template_assigns failed: #{Exception.message(e)}. Check that required data is loaded (e.g., override required_resources/0)."}
                  end
                else
                  {:ok, context.data}
                end

              case assigns_result do
                {:error, error_msg} ->
                  %{
                    channel: %{
                      transport: channel.transport,
                      audience: channel.audience
                    },
                    subject: subject,
                    html_body: nil,
                    text_body: nil,
                    from_address: from_address,
                    recipient: recipient,
                    audience: channel.audience,
                    transport: channel.transport,
                    notification_title: nil,
                    notification_message: nil,
                    error: error_msg
                  }

                {:ok, assigns} ->
                  {html_body, text_body, notification_title, notification_message} =
                    if channel.transport == :in_app do
                      title = EventResolver.notification_title(event_module, context, channel)
                      message = EventResolver.notification_message(event_module, context, channel)
                      {nil, nil, title, message}
                    else
                      try do
                        # Add subject to assigns so the layout can render it in the header
                        assigns_with_subject = Map.put(assigns, :subject, subject)

                        {html, text} =
                          render_templates(
                            event_module,
                            channel.transport,
                            variant,
                            assigns_with_subject
                          )

                        {html, text, nil, nil}
                      rescue
                        e ->
                          Logger.error("Template rendering failed: #{inspect(e)}")

                          Logger.error(
                            "Stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}"
                          )

                          {nil, nil, nil, nil}
                      end
                    end

                  %{
                    channel: %{
                      transport: channel.transport,
                      audience: channel.audience
                    },
                    subject: subject,
                    html_body: html_body,
                    text_body: text_body,
                    from_address: from_address,
                    recipient: recipient,
                    audience: channel.audience,
                    transport: channel.transport,
                    notification_title: notification_title,
                    notification_message: notification_message
                  }
              end
            end)

          {:ok, previews}
        end

      {:error, :not_found} ->
        {:error, "Event not found: #{event_id}"}
    end
  end

  # Private helpers

  defp has_email_channels?(event_id, event_module, event_config) do
    # Use EventResolver for safe callback execution
    sample_data = EventResolver.sample_data(event_module)
    context = %Context{event_id: event_id, data: sample_data, metadata: %{}}

    # Use centralized ChannelResolver for consistent priority logic
    # Pass DSL channels if available for proper resolution
    AshDispatch.ChannelResolver.has_transport?(
      event_id,
      event_module,
      context,
      :email,
      dsl_channels: event_config && event_config.channels
    )
  end

  # Look up the full event DSL config and the resource it's defined on
  defp get_event_dsl_config(event_id) do
    domains = Config.domains()

    result =
      Enum.find_value(domains, fn domain ->
        try do
          domain
          |> Ash.Domain.Info.resources()
          |> Enum.find_value(fn resource ->
            if AshDispatch.Resource.Info.dispatch_enabled?(resource) do
              resource
              |> AshDispatch.Resource.Info.events()
              |> Enum.find(fn event -> event.event_id == event_id end)
              |> case do
                nil -> nil
                event -> {:ok, event, resource}
              end
            else
              nil
            end
          end)
        rescue
          _ -> nil
        end
      end)

    result || :not_found
  end

  # Note: is_event_applicable_for_user? and build_sample_context are now handled by EventResolver

  defp build_context_from_data(event_id, event_module, context_data, actor) do
    # Normalize context_data keys to atoms (JSON sends string keys)
    context_data = atomize_keys(context_data)

    # Load data from DSL config, or fall back to event module sample_data for old-style events
    base_data_result =
      case get_event_dsl_config(event_id) do
        {:ok, event_config, resource} ->
          # Get data_key from config or derive from resource using Naming
          data_key = event_config.data_key || Naming.data_key(resource)
          id_field = String.to_atom("#{data_key}_id")
          load_opts = event_config.load || []

          # Load primary resource if ID is provided, or auto-load sample for preview
          cond do
            Map.has_key?(context_data, id_field) ->
              # ID provided - load that specific record
              resource_id = context_data[id_field]

              case load_resource(resource, resource_id, load_opts) do
                {:ok, record} ->
                  {:ok, %{data_key => record}}

                {:error, error} ->
                  Logger.error(
                    "Failed to load #{inspect(resource)} with id #{inspect(resource_id)}: #{inspect(error)}"
                  )

                  {:error, "Failed to load #{inspect(resource)} with id #{inspect(resource_id)}"}
              end

            map_size(context_data) == 0 ->
              # No context provided - try sample_data from module first, then auto-load from DB
              module_sample_data = EventResolver.sample_data(event_module)

              if map_size(module_sample_data) > 0 do
                # Use sample_data from event module
                {:ok, module_sample_data}
              else
                # Fall back to auto-loading a sample record from DB
                case load_sample_record(resource, load_opts) do
                  {:ok, record} ->
                    {:ok, %{data_key => record}}

                  {:error, :no_records} ->
                    {:error,
                     "No #{inspect(resource)} records found in database and no sample_data/0 defined in event module. " <>
                       "Either create a record or add sample_data/0 to #{inspect(event_module)}."}

                  {:error, error} ->
                    Logger.error("Failed to load sample #{inspect(resource)}: #{inspect(error)}")
                    {:error, "Failed to load sample record for preview"}
                end
              end

            true ->
              {:error,
               "Missing required field: #{id_field}. Provide the ID of the #{data_key} to preview."}
          end

        :not_found ->
          # Event module without DSL config - load data based on required_resources
          load_data_from_required_resources(event_module, context_data)
      end

    case base_data_result do
      {:error, reason} ->
        {:error, reason}

      {:ok, base_data} ->
        build_context_success(event_id, event_module, base_data, context_data, actor)
    end
  end

  # Load a sample record from the database for preview purposes
  defp load_sample_record(resource, load_opts) do
    domain = Ash.Resource.Info.domain(resource)

    case Ash.read(resource, domain: domain, authorize?: false, load: load_opts, page: [limit: 1]) do
      {:ok, %{results: [record | _]}} ->
        {:ok, record}

      {:ok, %{results: []}} ->
        {:error, :no_records}

      {:ok, [record | _]} ->
        {:ok, record}

      {:ok, []} ->
        {:error, :no_records}

      {:error, error} ->
        {:error, error}
    end
  end

  defp build_context_success(event_id, _event_module, base_data, context_data, actor) do
    # Merge any additional context_data (excluding ID fields)
    merged_data =
      context_data
      |> Map.drop(get_id_fields(context_data))
      |> then(&Map.merge(base_data, &1))

    # Note: prepare_data is for enriching changeset-based dispatch, not manual trigger
    # For manual trigger, we already have the loaded data - skip prepare_data
    enriched_data = merged_data

    # Get resource_key for context
    resource_key =
      case get_event_dsl_config(event_id) do
        {:ok, event_config, resource} ->
          event_config.data_key || Naming.data_key(resource)

        :not_found ->
          nil
      end

    {:ok,
     Context.new(
       event_id: event_id,
       data: enriched_data,
       resource_key: resource_key,
       metadata: %{actor: actor}
     )}
  end

  defp load_resource(resource, id, load_opts) do
    domain = Ash.Resource.Info.domain(resource)

    case Ash.get(resource, id, domain: domain, authorize?: false, load: load_opts) do
      {:ok, record} -> {:ok, record}
      {:error, _} = error -> error
    end
  end

  defp load_data_from_required_resources(event_module, context_data) do
    # Use EventResolver for safe callback execution
    resource = EventResolver.resource(event_module)

    if resource do
      try do
        # Get data_key from EventResolver or derive from resource
        data_key = EventResolver.data_key(event_module) || Naming.data_key(resource)

        # Get domain from EventResolver and convert to module
        domain_atom = EventResolver.domain(event_module)
        domain = if domain_atom, do: domain_to_module(domain_atom), else: nil

        id_field = String.to_atom("#{data_key}_id")

        # Get load options from event module's channels
        channel_load_opts = get_channel_load_opts(event_module)

        cond do
          Map.has_key?(context_data, id_field) ->
            # ID provided - load that specific record
            resource_id = context_data[id_field]

            case load_resource_with_domain(resource, resource_id, channel_load_opts, domain) do
              {:ok, record} ->
                {:ok, %{data_key => record}}

              {:error, error} ->
                Logger.error(
                  "Failed to load #{inspect(resource)} with id #{inspect(resource_id)}: #{inspect(error)}"
                )

                {:error, "Failed to load #{inspect(resource)} with id #{inspect(resource_id)}"}
            end

          map_size(context_data) == 0 ->
            # No context provided - try sample_data first, then fall back to DB
            sample_data = EventResolver.sample_data(event_module)

            if map_size(sample_data) > 0 do
              # Use sample_data from event module
              {:ok, sample_data}
            else
              # Fall back to loading a sample record from DB
              case load_sample_record_with_domain(resource, channel_load_opts, domain) do
                {:ok, record} ->
                  {:ok, %{data_key => record}}

                {:error, :no_records} ->
                  {:error,
                   "No #{inspect(resource)} records found in database and no sample_data/0 defined. " <>
                     "Either create a record or add sample_data/0 to the event module."}

                {:error, error} ->
                  Logger.error("Failed to load sample #{inspect(resource)}: #{inspect(error)}")
                  {:error, "Failed to load sample record for preview"}
              end
            end

          true ->
            {:error,
             "Missing required field: #{id_field}. Provide the ID of the #{data_key} to preview."}
        end
      rescue
        e ->
          Logger.error("Failed to load resource: #{inspect(e)}")
          {:error, "Failed to load resource: #{Exception.message(e)}"}
      end
    else
      # No resource/0 defined - try sample_data or use context_data
      sample_data = EventResolver.sample_data(event_module)

      cond do
        map_size(sample_data) > 0 ->
          {:ok, sample_data}

        map_size(context_data) > 0 ->
          {:ok, context_data}

        true ->
          {:error,
           "Event module has no resource/0 callback, no sample_data/0, and no context data provided. " <>
             "Add sample_data/0 to provide preview data, e.g.:\n\n" <>
             "  def sample_data do\n" <>
             "    %{user: %{id: Ash.UUID.generate(), email: \"test@example.com\"}}\n" <>
             "  end"}
      end
    end
  end

  # Load a sample record with explicit domain
  defp load_sample_record_with_domain(resource, load_opts, domain) do
    actual_domain =
      domain || (function_exported?(resource, :__domain__, 0) && resource.__domain__())

    if actual_domain do
      case Ash.read(resource,
             domain: actual_domain,
             authorize?: false,
             load: load_opts,
             page: [limit: 1]
           ) do
        {:ok, %{results: [record | _]}} -> {:ok, record}
        {:ok, %{results: []}} -> {:error, :no_records}
        {:ok, [record | _]} -> {:ok, record}
        {:ok, []} -> {:error, :no_records}
        {:error, error} -> {:error, error}
      end
    else
      {:error, "Could not determine domain for resource #{inspect(resource)}"}
    end
  end

  # Convert domain atom like :accounts to module like Magasin.Accounts
  defp domain_to_module(domain_atom) when is_atom(domain_atom) do
    # Get configured domains and find matching one
    domains = Config.domains()

    Enum.find(domains, fn domain_module ->
      domain_module
      |> Module.split()
      |> List.last()
      |> Macro.underscore()
      |> String.to_atom() == domain_atom
    end)
  end

  defp load_resource_with_domain(resource, id, load_opts, domain) do
    # Use provided domain or try to get from resource
    actual_domain =
      domain || (function_exported?(resource, :__domain__, 0) && resource.__domain__())

    if actual_domain do
      Ash.get(resource, id, domain: actual_domain, authorize?: false, load: load_opts)
    else
      {:error, "Could not determine domain for resource #{inspect(resource)}"}
    end
  end

  # Get aggregated load options from all channels defined by event module
  defp get_channel_load_opts(event_module) do
    # Use empty context to get channel definitions
    sample_context = %Context{event_id: "", data: %{}, metadata: %{}}

    # Use centralized ChannelResolver for consistent priority logic
    channels = AshDispatch.ChannelResolver.get_module_channels(event_module, sample_context)

    # Aggregate load options from all channels
    channels
    |> Enum.flat_map(fn channel -> Map.get(channel, :load, []) end)
    |> Enum.uniq()
  end

  defp get_id_fields(context_data) do
    context_data
    |> Map.keys()
    |> Enum.filter(&String.ends_with?(to_string(&1), "_id"))
  end

  defp get_filtered_channels(event_module, context, nil) do
    # Use centralized ChannelResolver for consistent priority logic
    channels = AshDispatch.ChannelResolver.resolve(context.event_id, event_module, context)
    {:ok, channels}
  end

  defp get_filtered_channels(event_module, context, channel_filter) do
    # Use centralized ChannelResolver for consistent priority logic
    channels = AshDispatch.ChannelResolver.resolve(context.event_id, event_module, context)

    # Apply user-specified filters
    filtered =
      Enum.filter(channels, fn channel ->
        Enum.all?(channel_filter, fn {key, value} ->
          Map.get(channel, key) == value
        end)
      end)

    {:ok, filtered}
  end

  defp get_preview_recipient(event_module, context, channel) do
    # Use EventResolver for safe callback execution
    case EventResolver.recipients(event_module, context, channel) do
      [first | _] -> format_recipient(first)
      [] -> "preview@example.com"
    end
  end

  defp format_recipient(%{display_name: name, email: email})
       when is_binary(name) and name != "" do
    "#{name} <#{email}>"
  end

  defp format_recipient(%{email: email}) when is_binary(email), do: email
  defp format_recipient(email) when is_binary(email), do: email
  defp format_recipient(_), do: "preview@example.com"

  defp render_templates(event_module, transport, variant, assigns) do
    # Get otp_app from config - needed for priv manifest lookup
    otp_app = Config.otp_app()

    # TemplateResolver auto-derives event_dir from module source when not provided
    html =
      case AshDispatch.TemplateResolver.render(
             event_module: event_module,
             format: :html,
             transport: transport,
             variant: variant,
             assigns: assigns,
             otp_app: otp_app
           ) do
        {:ok, rendered} -> rendered
        {:error, _} -> nil
      end

    text =
      case AshDispatch.TemplateResolver.render(
             event_module: event_module,
             format: :text,
             transport: transport,
             variant: variant,
             assigns: assigns,
             otp_app: otp_app
           ) do
        {:ok, rendered} -> rendered
        {:error, _} -> nil
      end

    {html, text}
  end

  defp get_event_description(nil, event_id) do
    # For events without a module, derive description from event_id
    # e.g., "user.password_reset" -> "User > Password Reset"
    case String.split(event_id || "", ".") do
      [domain, event_name] ->
        formatted_domain = domain |> Macro.camelize()

        formatted_event =
          event_name
          |> String.replace("_", " ")
          |> String.split()
          |> Enum.map(&String.capitalize/1)
          |> Enum.join(" ")

        "#{formatted_domain} > #{formatted_event}"

      _ ->
        "Email event"
    end
  end

  defp get_event_description(event_module, _event_id) do
    case Module.split(event_module) do
      parts when length(parts) >= 5 ->
        domain = Enum.at(parts, 1)
        event_name = Enum.at(parts, -2)

        formatted_event =
          event_name
          |> String.replace(~r/([A-Z])/, " \\1")
          |> String.trim()

        "#{domain} > #{formatted_event}"

      _ ->
        "Email event"
    end
  end

  # Note: get_domain is now handled directly via EventResolver.domain/1 in list_available_events

  # Format required_resources from EventResolver output
  defp format_required_resources(required_resources) do
    Enum.map(required_resources, fn
      {key, resource_module} when is_atom(resource_module) ->
        %{
          key: to_string(key),
          resource: inspect(resource_module),
          filter: nil
        }

      {key, {resource_module, opts}} when is_atom(resource_module) ->
        filter = Keyword.get(opts, :filter)

        %{
          key: to_string(key),
          resource: inspect(resource_module),
          filter: if(filter, do: Enum.into(filter, %{}), else: nil)
        }

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
    # Derive required context from DSL config
    case get_event_dsl_config(event_id) do
      {:ok, event_config, resource} ->
        data_key = event_config.data_key || Naming.data_key(resource)
        id_field = "#{data_key}_id"
        [id_field]

      :not_found ->
        []
    end
  end

  defp get_example_context(event_id, event_module) do
    # Use EventResolver for safe sample_data retrieval
    sample_data = EventResolver.sample_data(event_module)
    # If sample_data is empty, use default example context
    if map_size(sample_data) > 0, do: sample_data, else: build_default_example_context(event_id)
  end

  defp build_default_example_context(event_id) do
    # Derive example context from DSL config
    case get_event_dsl_config(event_id) do
      {:ok, event_config, resource} ->
        data_key = event_config.data_key || Naming.data_key(resource)
        id_field = String.to_atom("#{data_key}_id")
        %{id_field => "uuid-here"}

      :not_found ->
        %{}
    end
  end

  defp maybe_add_filter(map, _key, nil), do: map
  defp maybe_add_filter(map, key, value), do: Map.put(map, key, value)

  defp maybe_add_to_map(map, _key, nil), do: map

  defp maybe_add_to_map(map, key, value) do
    Map.put(map, key, value)
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {String.to_atom(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp atomize_keys(value), do: value
end
