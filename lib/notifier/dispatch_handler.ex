defmodule AshDispatch.Notifier.DispatchHandler do
  @moduledoc """
  Side-effect orchestration for dispatch events — extracted from the
  prior `AshDispatch.Changes.DispatchEvent` module.

  ## Why this exists separately from the notifier

  `AshDispatch.Notifier` is a thin adapter that pattern-matches the
  notification's action and looks up per-action config. The actual
  dispatch logic — event-module resolution, context building, channel
  resolution, dispatcher invocation — lives here. This isolates the
  "what to dispatch" decisions (Notifier) from the "how to dispatch"
  orchestration (DispatchHandler).

  ## Two modes (preserved verbatim from the prior change module)

  - **DSL-based** — driven by an `event :foo, ... end` block that the
    transformer persisted as a config map with `:event_config`.
  - **Standalone** — for events that bypass the DSL block and were
    historically registered via `change DispatchEvent, event_id, data_key`.
    Mosis has zero such callers today; the path is preserved for
    AshDispatch substrate completeness.
  """

  alias AshDispatch.{ChannelResolver, Config, Context, Dispatcher, EventResolver}

  require Logger

  @doc """
  Dispatch a single event for a notification.

  Takes the notification (an `%Ash.Notifier.Notification{}`) and the
  per-action `event_config` persisted by `InjectDispatchChanges`.
  Equivalent to the prior `dispatch_event/4` private function called
  from the change's `after_action` hook.
  """
  @spec dispatch(Ash.Notifier.Notification.t(), map()) :: :ok
  def dispatch(%Ash.Notifier.Notification{} = notification, %{} = config) do
    changeset = notification.changeset
    record = notification.data

    # The change-module-era input shape was {opts, ash_context}; reconstruct
    # an equivalent ash_context from the notification.
    ash_context = ash_context_from_notification(notification)

    case Map.fetch(config, :event_config) do
      {:ok, event_config} ->
        dispatch_dsl_event(changeset, record, config, ash_context, event_config)

      :error ->
        dispatch_standalone_event(changeset, record, config, ash_context)
    end
  rescue
    error ->
      Logger.error("""
      [AshDispatch.Notifier.DispatchHandler] dispatch failed for #{config[:event_id]}
      Error: #{inspect(error)}
      Stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}
      """)

      # Don't fail the notification — same posture as the prior change
      # module (dispatch_event.ex:127-137).
      :ok
  end

  # ── Mode 1: DSL-based event dispatch (preserved verbatim) ───────

  defp dispatch_dsl_event(changeset, record, opts, ash_context, event_config) do
    event_id = Map.fetch!(opts, :event_id)
    load = Map.get(opts, :load, [])
    data_key = Map.get(event_config, :data_key)
    include_actor_as = Map.get(event_config, :include_actor_as)

    # Always resolve module at runtime via EventResolver
    # Compile-time resolution is unreliable due to module compilation order
    # (event modules compile after resources, so Code.ensure_loaded? fails)
    event_module =
      case EventResolver.find_module(event_id) do
        {:ok, m} ->
          m

        {:error, :not_found} ->
          Logger.warning(
            "[AshDispatch] No event module found for #{event_id} - callbacks (prepare_data, prepare_template_assigns) will not be called"
          )

          nil
      end

    record = maybe_load_relationships(record, load, changeset)

    context =
      build_context(
        event_id,
        record,
        changeset,
        ash_context,
        data_key,
        include_actor_as,
        event_config
      )

    context = maybe_enrich_context_with_prepare_data(context, changeset, record, event_module)

    context =
      if event_module do
        case EventResolver.generate_send_variables(
               event_module,
               context,
               context.variables || %{}
             ) do
          {:ok, enhanced_variables} ->
            %{context | variables: enhanced_variables}

          {:error, reason} ->
            Logger.error(
              "[AshDispatch] generate_send_variables failed for #{event_id}: #{inspect(reason)}"
            )

            context
        end
      else
        context
      end

    channels = resolve_channels(context, event_config, event_module)

    Enum.each(channels, fn channel ->
      Dispatcher.dispatch_channel(context, channel, event_config)
    end)

    :ok
  end

  # ── Mode 2: Standalone event dispatch (preserved verbatim) ──────

  defp dispatch_standalone_event(changeset, record, opts, _ash_context) do
    event_id = Map.fetch!(opts, :event_id)
    data_key = Map.fetch!(opts, :data_key)
    load = Map.get(opts, :load, [])

    record = maybe_load_relationships(record, load, changeset)

    data =
      case EventResolver.find_module(event_id) do
        {:ok, event_module} ->
          prepared_data = EventResolver.prepare_data(event_module, changeset, record)

          if map_size(prepared_data) == 0 do
            Map.put(%{}, data_key, record)
          else
            prepared_data
          end

        {:error, :not_found} ->
          Map.put(%{}, data_key, record)
      end

    case Dispatcher.dispatch(event_id, data) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to dispatch standalone event #{event_id}: #{inspect(reason)}")
        :ok
    end
  end

  # ── Helpers (preserved verbatim from dispatch_event.ex) ─────────

  defp ash_context_from_notification(%Ash.Notifier.Notification{} = notification) do
    # The change-module API received an Ash context map; the notification
    # carries actor + tenant separately and the rest is in changeset.context.
    base = (notification.changeset && notification.changeset.context) || %{}
    Map.put(base, :actor, notification.actor)
  end

  defp maybe_load_relationships(record, [], _changeset), do: record

  defp maybe_load_relationships(record, load, changeset) do
    domain = (changeset && changeset.domain) || record.__struct__.__domain__()

    case Ash.load(record, load, domain: domain, authorize?: false) do
      {:ok, loaded_record} ->
        loaded_record

      {:error, error} ->
        Logger.warning("""
        Failed to load relationships #{inspect(load)} for event dispatch
        Error: #{inspect(error)}
        Continuing with unloaded record...
        """)

        record
    end
  end

  defp build_context(
         event_id,
         record,
         changeset,
         ash_context,
         data_key,
         include_actor_as,
         event_config
       ) do
    resource_key = data_key || record.__struct__.__schema__(:source)
    actor = Map.get(ash_context, :actor)

    data =
      %{resource_key => record, :actor => actor}
      |> maybe_add_actor_alias(actor, include_actor_as)

    locale_from = Map.get(event_config, :locale_from)
    default_locale = Map.get(event_config, :default_locale) || Config.default_locale()
    locale = extract_locale_from_record(record, locale_from, default_locale)

    %Context{
      event_id: event_id,
      data: data,
      resource_key: resource_key,
      priority: Map.get(event_config, :priority, :standard),
      user: actor,
      source: :resource_action,
      locale: locale,
      base_url: get_base_url(),
      now: DateTime.utc_now(),
      metadata: %{
        action: changeset.action.name,
        action_type: changeset.action.type
      }
    }
  end

  defp extract_locale_from_record(record, locale_from, default_locale) do
    cond do
      locale_from && Map.has_key?(record, locale_from) && Map.get(record, locale_from) ->
        Map.get(record, locale_from)

      Map.has_key?(record, :visitor_locale) && record.visitor_locale ->
        record.visitor_locale

      Map.has_key?(record, :locale) && record.locale ->
        record.locale

      true ->
        default_locale
    end
  end

  defp maybe_add_actor_alias(data, _actor, nil), do: data
  defp maybe_add_actor_alias(data, actor, alias_key), do: Map.put(data, alias_key, actor)

  defp maybe_enrich_context_with_prepare_data(context, _changeset, _record, nil), do: context

  defp maybe_enrich_context_with_prepare_data(context, changeset, record, event_module) do
    prepared_data = EventResolver.prepare_data(event_module, changeset, record)

    if map_size(prepared_data) > 0 do
      %{context | data: Map.merge(context.data, prepared_data)}
    else
      context
    end
  end

  defp get_base_url do
    cond do
      endpoint = Config.endpoint() ->
        endpoint.url()

      host = System.get_env("PHX_HOST") ->
        scheme = System.get_env("PHX_SCHEME", "https")
        port = System.get_env("PHX_PORT", "443")

        case {scheme, port} do
          {"https", "443"} -> "#{scheme}://#{host}"
          {"http", "80"} -> "#{scheme}://#{host}"
          _ -> "#{scheme}://#{host}:#{port}"
        end

      base_url = Config.base_url() ->
        base_url

      true ->
        "http://localhost:4000"
    end
  end

  defp resolve_channels(context, event_config, event_module) do
    ChannelResolver.resolve(
      context.event_id,
      event_module,
      context,
      dsl_channels: Map.get(event_config, :channels)
    )
  end
end
