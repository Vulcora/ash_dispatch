defmodule AshDispatch.Resources.ManualTrigger.Helpers do
  @moduledoc false
  # Helper functions for ManualTrigger resources

  alias AshDispatch.Context

  require Logger

  def list_available_events(user) do
    # Get DSL events (primary source)
    dsl_events = list_dsl_events()
    dsl_event_ids = MapSet.new(dsl_events, fn {event_id, _, _} -> event_id end)

    # Get event module events (fallback for events not in DSL)
    module_events =
      Application.get_env(:ash_dispatch, :event_modules, [])
      |> Enum.reject(fn {event_id, _} -> MapSet.member?(dsl_event_ids, event_id) end)
      |> Enum.map(fn {event_id, event_module} -> {event_id, event_module, nil} end)

    # Combine both sources
    all_events = dsl_events ++ module_events

    all_events
    |> Enum.filter(fn {_event_id, event_module, _event_config} ->
      has_email_channels?(event_module) &&
        is_event_applicable_for_user?(event_module, user)
    end)
    |> Enum.map(fn {event_id, event_module, event_config} ->
      # Get channels from DSL config or event module
      channels =
        if event_config do
          convert_dsl_channels_to_structs(event_config.channels || [])
        else
          get_channels_from_module(event_id, event_module)
        end

      %{
        event_id: event_id,
        description: get_event_description(event_module),
        domain: get_domain(event_module),
        channels: format_channels(channels),
        required_context: get_required_context(event_id),
        example_context: get_example_context(event_id, event_module),
        required_resources: get_required_resources(event_module)
      }
    end)
    |> Enum.sort_by(& &1.event_id)
  end

  defp get_channels_from_module(event_id, event_module) do
    sample_context = build_sample_context(event_id, event_module)

    if function_exported?(event_module, :channels, 1) do
      try do
        event_module.channels(sample_context)
      rescue
        _ -> []
      end
    else
      []
    end
  end

  defp list_dsl_events do
    domains = Application.get_env(:ash_dispatch, :domains, [])

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

  defp convert_dsl_channels_to_structs(channels) when is_list(channels) do
    Enum.map(channels, fn
      %AshDispatch.Dsl.Channel{} = channel ->
        # Already a DSL channel struct, convert to runtime channel
        %AshDispatch.Channel{
          transport: channel.transport,
          audience: channel.audience,
          time: channel.time,
          policy: channel.policy,
          variant: channel.variant,
          webhook_url: channel.webhook_url,
          content: channel.content,
          metadata: channel.metadata,
          opts: channel.opts,
          load: channel.load
        }

      channel when is_list(channel) ->
        # Keyword list format from DSL
        %AshDispatch.Channel{
          transport: Keyword.fetch!(channel, :transport),
          audience: Keyword.fetch!(channel, :audience),
          time: Keyword.get(channel, :time, {:in, 0}),
          policy: Keyword.get(channel, :policy, :always),
          variant: Keyword.get(channel, :variant),
          webhook_url: Keyword.get(channel, :webhook_url),
          content: Keyword.get(channel, :content, %{}),
          metadata: Keyword.get(channel, :metadata, %{}),
          opts: Keyword.get(channel, :opts, %{}),
          load: Keyword.get(channel, :load, [])
        }

      channel ->
        channel
    end)
  end

  def get_user_preference_for_event(user_id, event_id) do
    event_modules = Application.get_env(:ash_dispatch, :event_modules, [])

    case Enum.find(event_modules, fn {id, _mod} -> id == event_id end) do
      {_id, event_module} ->
        sample_context = build_sample_context(event_id, event_module)

        user_configurable =
          if function_exported?(event_module, :user_configurable?, 1) do
            try do
              event_module.user_configurable?(sample_context)
            rescue
              _ -> false
            end
          else
            false
          end

        category =
          if user_configurable && function_exported?(event_module, :category, 1) do
            try do
              event_module.category(sample_context)
            rescue
              _ -> nil
            end
          else
            nil
          end

        preference_enabled =
          if user_configurable && category do
            preference_provider = Application.get_env(:ash_dispatch, :preference_provider)

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

      nil ->
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
    event_modules = Application.get_env(:ash_dispatch, :event_modules, [])

    case Enum.find(event_modules, fn {id, _mod} -> id == event_id end) do
      {_id, event_module} ->
        # Load the resource data using the same logic as preview
        case build_context_from_data(event_id, event_module, context_data, actor) do
          {:ok, context} ->
            # Generate real variables if event module implements generate_send_variables/2
            # This allows events to provide real data (tokens, etc.) for actual sending
            # while using sample_data() for previews
            enhanced_opts_result =
              if function_exported?(event_module, :generate_send_variables, 2) do
                event_module.generate_send_variables(context, opts)
              else
                {:ok, opts}
              end

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

      nil ->
        {:error, "Event #{event_id} not found"}
    end
  end

  def preview_trigger(event_id, context_data, channel_filter, recipient_email, actor) do
    event_modules = Application.get_env(:ash_dispatch, :event_modules, [])

    case Enum.find(event_modules, fn {id, _mod} -> id == event_id end) do
      {_id, event_module} ->
        with {:ok, context} <-
               build_context_from_data(event_id, event_module, context_data, actor),
             {:ok, channels} <- get_filtered_channels(event_module, context, channel_filter) do
          previews =
            Enum.map(channels, fn channel ->
              subject =
                if function_exported?(event_module, :subject, 2) do
                  try do
                    event_module.subject(context, channel)
                  rescue
                    e ->
                      Logger.error("Subject computation failed: #{inspect(e)}")
                      nil
                  end
                else
                  nil
                end

              {_from_name, from_address} =
                if function_exported?(event_module, :from, 2) do
                  try do
                    event_module.from(context, channel)
                  rescue
                    _ -> {"", ""}
                  end
                else
                  {"", ""}
                end

              recipient = recipient_email || get_preview_recipient(event_module, context, channel)

              variant =
                if function_exported?(event_module, :template_variant, 2) do
                  try do
                    event_module.template_variant(context, channel)
                  rescue
                    _ -> nil
                  end
                else
                  nil
                end

              assigns_result =
                if function_exported?(event_module, :prepare_template_assigns, 2) do
                  try do
                    base_assigns = event_module.prepare_template_assigns(context, channel)
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
                      title =
                        if function_exported?(event_module, :notification_title, 2) do
                          try do
                            event_module.notification_title(context, channel)
                          rescue
                            _ -> nil
                          end
                        else
                          nil
                        end

                      message =
                        if function_exported?(event_module, :notification_message, 2) do
                          try do
                            event_module.notification_message(context, channel)
                          rescue
                            _ -> nil
                          end
                        else
                          nil
                        end

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

      nil ->
        {:error, "Event not found: #{event_id}"}
    end
  end

  # Private helpers

  defp has_email_channels?(event_module) do
    if function_exported?(event_module, :sample_data, 0) do
      try do
        sample_data = event_module.sample_data()
        event_id = if function_exported?(event_module, :id, 0), do: event_module.id(), else: nil
        context = %Context{event_id: event_id || "sample", data: sample_data, metadata: %{}}

        channels =
          if function_exported?(event_module, :channels, 1) do
            event_module.channels(context)
          else
            []
          end

        channels =
          if channels == [] && event_id do
            get_inline_dsl_channels(event_id)
          else
            channels
          end

        Enum.any?(channels, &(&1.transport == :email))
      rescue
        _ -> false
      end
    else
      false
    end
  end

  defp get_inline_dsl_channels(event_id) do
    case get_event_dsl_config(event_id) do
      {:ok, event_config, _resource} -> event_config.channels
      :not_found -> []
    end
  end

  # Look up the full event DSL config and the resource it's defined on
  defp get_event_dsl_config(event_id) do
    domains = Application.get_env(:ash_dispatch, :domains, [])

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

  defp is_event_applicable_for_user?(_event_module, nil), do: true

  defp is_event_applicable_for_user?(event_module, user) do
    if function_exported?(event_module, :applicable_for_user?, 1) do
      try do
        event_module.applicable_for_user?(user)
      rescue
        _ -> true
      end
    else
      true
    end
  end

  defp build_sample_context(event_id, event_module) do
    sample_data =
      if function_exported?(event_module, :sample_data, 0) do
        try do
          event_module.sample_data()
        rescue
          _ -> %{}
        end
      else
        %{}
      end

    %Context{
      event_id: event_id,
      data: sample_data,
      metadata: %{}
    }
  end

  defp build_context_from_data(event_id, event_module, context_data, actor) do
    # Normalize context_data keys to atoms (JSON sends string keys)
    context_data = atomize_keys(context_data)

    # Load data from DSL config, or fall back to event module sample_data for old-style events
    base_data_result =
      case get_event_dsl_config(event_id) do
        {:ok, event_config, resource} ->
          # Get data_key from config or derive from resource
          data_key = event_config.data_key || derive_data_key(resource)
          id_field = String.to_atom("#{data_key}_id")

          # Load primary resource if ID is provided
          if Map.has_key?(context_data, id_field) do
            resource_id = context_data[id_field]
            load_opts = event_config.load || []

            case load_resource(resource, resource_id, load_opts) do
              {:ok, record} ->
                {:ok, %{data_key => record}}

              {:error, error} ->
                Logger.error(
                  "Failed to load #{inspect(resource)} with id #{inspect(resource_id)}: #{inspect(error)}"
                )

                {:error, "Failed to load #{inspect(resource)} with id #{inspect(resource_id)}"}
            end
          else
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
          event_config.data_key || derive_data_key(resource)

        :not_found ->
          nil
      end

    {:ok,
     %Context{
       event_id: event_id,
       data: enriched_data,
       resource_key: resource_key,
       metadata: %{actor: actor}
     }}
  end

  defp derive_data_key(resource) do
    resource
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_atom()
  end

  defp load_resource(resource, id, load_opts) do
    domain = resource.__domain__()

    case Ash.get(resource, id, domain: domain, authorize?: false, load: load_opts) do
      {:ok, record} -> {:ok, record}
      {:error, _} = error -> error
    end
  end

  defp load_data_from_required_resources(event_module, context_data) do
    # Check for resource/0 callback (mirrors DSL pattern)
    if function_exported?(event_module, :resource, 0) do
      try do
        resource = event_module.resource()

        # Get data_key from callback or derive from resource
        data_key =
          if function_exported?(event_module, :data_key, 0) do
            event_module.data_key()
          else
            derive_data_key(resource)
          end

        # Get domain from event module's domain/0 callback
        domain =
          if function_exported?(event_module, :domain, 0) do
            # Convert atom domain to module name
            domain_atom = event_module.domain()
            domain_to_module(domain_atom)
          else
            nil
          end

        id_field = String.to_atom("#{data_key}_id")

        # Get load options from event module's channels
        channel_load_opts = get_channel_load_opts(event_module)

        if Map.has_key?(context_data, id_field) do
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
        else
          {:error,
           "Missing required field: #{id_field}. Provide the ID of the #{data_key} to preview."}
        end
      rescue
        e ->
          Logger.error("Failed to load resource: #{inspect(e)}")
          {:error, "Failed to load resource: #{Exception.message(e)}"}
      end
    else
      # No resource/0 defined, use context_data directly
      if map_size(context_data) > 0 do
        {:ok, context_data}
      else
        {:error,
         "Event module has no resource/0 callback and no context data provided. " <>
           "Add resource/0 to specify the primary resource, e.g.:\n\n" <>
           "  def resource, do: MyApp.Accounts.User"}
      end
    end
  end

  # Convert domain atom like :accounts to module like Magasin.Accounts
  defp domain_to_module(domain_atom) when is_atom(domain_atom) do
    # Get configured domains and find matching one
    domains = Application.get_env(:ash_dispatch, :domains, [])

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
    if function_exported?(event_module, :channels, 1) do
      try do
        # Use empty context to get channel definitions
        sample_context = %Context{event_id: "", data: %{}, metadata: %{}}
        channels = event_module.channels(sample_context)

        # Aggregate load options from all channels
        channels
        |> Enum.flat_map(fn channel -> Map.get(channel, :load, []) end)
        |> Enum.uniq()
      rescue
        _ -> []
      end
    else
      []
    end
  end

  defp get_id_fields(context_data) do
    context_data
    |> Map.keys()
    |> Enum.filter(&String.ends_with?(to_string(&1), "_id"))
  end

  defp get_filtered_channels(event_module, context, nil) do
    if function_exported?(event_module, :channels, 1) do
      channels =
        try do
          event_module.channels(context)
        rescue
          _ -> []
        end

      {:ok, channels}
    else
      {:ok, []}
    end
  end

  defp get_filtered_channels(event_module, context, channel_filter) do
    if function_exported?(event_module, :channels, 1) do
      channels =
        try do
          event_module.channels(context)
        rescue
          _ -> []
        end

      filtered =
        Enum.filter(channels, fn channel ->
          Enum.all?(channel_filter, fn {key, value} ->
            Map.get(channel, key) == value
          end)
        end)

      {:ok, filtered}
    else
      {:ok, []}
    end
  end

  defp get_preview_recipient(event_module, context, channel) do
    if function_exported?(event_module, :recipients, 2) do
      try do
        case event_module.recipients(context, channel) do
          [first | _] -> first
          [] -> "preview@example.com"
        end
      rescue
        _ -> "preview@example.com"
      end
    else
      "preview@example.com"
    end
  end

  defp render_templates(event_module, transport, variant, assigns) do
    # Get otp_app from config - needed for priv manifest lookup
    otp_app = Application.get_env(:ash_dispatch, :otp_app)

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

  defp get_event_description(event_module) do
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

  defp get_domain(event_module) do
    if function_exported?(event_module, :domain, 0) do
      try do
        event_module.domain() |> to_string()
      rescue
        _ -> nil
      end
    else
      nil
    end
  end

  defp get_required_resources(event_module) do
    if function_exported?(event_module, :required_resources, 0) do
      try do
        event_module.required_resources()
        |> Enum.map(fn
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
      rescue
        _ -> []
      end
    else
      []
    end
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
        data_key = event_config.data_key || derive_data_key(resource)
        id_field = "#{data_key}_id"
        [id_field]

      :not_found ->
        []
    end
  end

  defp get_example_context(event_id, event_module) do
    if function_exported?(event_module, :sample_data, 0) do
      try do
        event_module.sample_data()
      rescue
        _ -> build_default_example_context(event_id)
      end
    else
      build_default_example_context(event_id)
    end
  end

  defp build_default_example_context(event_id) do
    # Derive example context from DSL config
    case get_event_dsl_config(event_id) do
      {:ok, event_config, resource} ->
        data_key = event_config.data_key || derive_data_key(resource)
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
