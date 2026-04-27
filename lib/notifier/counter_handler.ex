defmodule AshDispatch.Notifier.CounterHandler do
  @moduledoc """
  Side-effect orchestration for counter broadcasts — extracted from the
  prior `AshDispatch.Changes.BroadcastCounterUpdate` module.

  ## Why this exists separately from the notifier

  `AshDispatch.Notifier` is a thin adapter that pattern-matches the
  notification's action and looks up per-action config. The actual
  counter logic — recipient resolution (relationship-based, filter-
  based, MFA-based), query execution with scoping/filtering, and the
  configured `counter_broadcast_fn` invocation — lives here. This
  isolates the "what to broadcast" decisions (Notifier) from the "how
  to broadcast" orchestration (CounterHandler).

  ## Preserved verbatim from the prior change module

  The recipient resolution, query construction, scope-expression
  application, filter-by-record, and broadcast invocation logic is
  carried over unchanged from `Changes.BroadcastCounterUpdate`. The
  ONLY behavioural change is **when** this code runs: it used to fire
  via `Ash.Changeset.after_action/2` synchronously inside the action's
  transaction; it now fires from `Ash.Notifier.notify/1` post-commit
  (or is dropped on rollback).
  """

  alias AshDispatch.Config
  alias AshDispatch.Helpers.ResourceIntrospection

  require Ash.Query
  require Logger

  @doc """
  Broadcast a single counter for a notification.

  Takes the notification (an `%Ash.Notifier.Notification{}`) and the
  per-action `counter_config` persisted by `InjectCounterBroadcasts`.
  Equivalent to the prior `broadcast_counter/2` private function
  called from the change's `after_action` hook.
  """
  @spec broadcast(Ash.Notifier.Notification.t(), keyword() | map()) :: :ok
  def broadcast(%Ash.Notifier.Notification{} = notification, config) do
    record = notification.data
    opts = config_to_opts(config)
    broadcast_counter(record, opts)
  end

  defp config_to_opts(config) when is_list(config), do: config

  defp config_to_opts(config) when is_map(config) do
    config
    |> Map.to_list()
    |> Enum.reject(fn {k, _} -> k == :__struct__ end)
  end

  # ── broadcast_counter — preserved verbatim from BroadcastCounterUpdate ──

  defp broadcast_counter(record, opts) do
    counter_name = Keyword.fetch!(opts, :counter_name)
    resource = Keyword.fetch!(opts, :resource)
    query_filter = Keyword.fetch!(opts, :query_filter)
    audience = Keyword.fetch!(opts, :audience)
    invalidates = Keyword.get(opts, :invalidates, [])
    filter_by_record = Keyword.get(opts, :filter_by_record)

    recipients = resolve_recipients_for_counter(record, audience, opts)

    authorize? = Keyword.get(opts, :authorize?, true)
    scope = Keyword.get(opts, :scope)

    user_id_path =
      ResourceIntrospection.resolve_user_id_path_for_scoping(resource,
        authorize?: authorize?,
        scope: scope,
        user_id_path: Keyword.get(opts, :user_id_path),
        audience: audience
      )

    Enum.each(recipients, fn recipient ->
      count =
        try do
          query =
            resource
            |> Ash.Query.new()

          query = apply_query_filter(query, query_filter)

          query =
            cond do
              scope && !filter_by_record ->
                apply_scope_expression(query, scope, recipient)

              user_id_path && !filter_by_record ->
                user_filter = ResourceIntrospection.build_user_filter(user_id_path, recipient.id)
                Ash.Query.do_filter(query, user_filter)

              true ->
                query
            end

          query = apply_filter_by_record(query, record, filter_by_record)

          Ash.count!(query, authorize?: authorize?, actor: recipient)
        rescue
          e ->
            Logger.error(
              "[AshDispatch.Notifier.CounterHandler] Failed to count #{counter_name}: #{inspect(e)}\n" <>
                "Resource: #{inspect(resource)}, Query filter: #{inspect(query_filter)}"
            )

            0
        end

      broadcast_to_user(recipient.id, counter_name, count, invalidates, audience)
    end)
  end

  # ── Recipient resolution — preserved verbatim ──────────────────

  defp resolve_recipients_for_counter(record, audience, opts) do
    if ResourceIntrospection.is_relationship_audience?(audience) do
      case extract_user_from_record(record, audience, opts) do
        nil -> []
        user -> [user]
      end
    else
      context = %{data: %{record: record}}
      channel = %{audience: audience}
      AshDispatch.Event.Helpers.resolve_recipients_for_audience(context, channel)
    end
  end

  defp extract_user_from_record(record, audience, opts) do
    user_id = extract_user_id(record, audience, opts)

    if user_id do
      %{id: user_id}
    else
      nil
    end
  end

  defp extract_user_id(record, audience, opts) do
    case Keyword.get(opts, :user_id_path) do
      nil ->
        relationship_name = ResourceIntrospection.get_audience_relationship(audience)

        user_id_field =
          Keyword.get(opts, :user_id_field) ||
            (relationship_name && String.to_atom("#{relationship_name}_id")) ||
            :user_id

        Map.get(record, user_id_field)

      path when is_list(path) ->
        case load_and_traverse_path(record, path) do
          {:ok, user_id} ->
            user_id

          {:error, reason} ->
            Logger.warning(
              "[AshDispatch.Notifier.CounterHandler] Failed to resolve user_id via path #{inspect(path)}: #{inspect(reason)}"
            )

            nil
        end
    end
  end

  defp load_and_traverse_path(record, path) do
    {relationships, [_final_field]} = Enum.split(path, -1)

    case Ash.load(record, relationships, authorize?: false) do
      {:ok, loaded_record} ->
        value = get_nested_value(loaded_record, path)
        {:ok, value}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_nested_value(record, [field]), do: Map.get(record, field)

  defp get_nested_value(record, [field | rest]) do
    case Map.get(record, field) do
      nil -> nil
      nested_record -> get_nested_value(nested_record, rest)
    end
  end

  # ── Query filter / scope / filter_by_record — preserved verbatim ──

  defp apply_query_filter(query, nil), do: query
  defp apply_query_filter(query, []), do: query

  defp apply_query_filter(query, query_filter) when is_list(query_filter) do
    if Keyword.keyword?(query_filter) do
      Enum.reduce(query_filter, query, fn {field, value}, acc_query ->
        import Ash.Query
        import Ash.Expr

        if is_list(value) do
          filter(acc_query, ^ref(field) in ^value)
        else
          filter(acc_query, ^ref(field) == ^value)
        end
      end)
    else
      Logger.warning(
        "[AshDispatch.Notifier.CounterHandler] Unknown query_filter format (non-keyword list): #{inspect(query_filter)}"
      )

      query
    end
  end

  defp apply_query_filter(query, query_filter) do
    Ash.Query.filter(query, ^query_filter)
  rescue
    e ->
      Logger.warning(
        "[AshDispatch.Notifier.CounterHandler] Failed to apply query_filter: #{inspect(e)}, filter: #{inspect(query_filter)}"
      )

      query
  end

  defp apply_scope_expression(query, scope_expr, recipient) do
    query
    |> Ash.Query.set_context(%{actor: recipient})
    |> Ash.Query.filter(^scope_expr)
  end

  defp apply_filter_by_record(query, _record, nil), do: query

  defp apply_filter_by_record(query, record, filter_config) do
    filter_field = get_config_value(filter_config, :field)
    record_field = get_config_value(filter_config, :record_field, :id)

    if filter_field do
      filter_value = Map.get(record, record_field)

      if filter_value do
        import Ash.Query
        import Ash.Expr

        filter(query, ^ref(filter_field) == ^filter_value)
      else
        Logger.warning(
          "[AshDispatch.Notifier.CounterHandler] Could not extract #{record_field} from record for filtering"
        )

        query
      end
    else
      query
    end
  end

  defp get_config_value(config, key, default \\ nil) do
    cond do
      is_list(config) -> Keyword.get(config, key, default)
      is_map(config) -> Map.get(config, key, default)
      true -> default
    end
  end

  # ── Broadcast — preserved verbatim ─────────────────────────────

  defp broadcast_to_user(user_id, counter_name, count, invalidates, _audience) do
    case Config.counter_broadcast_fn() do
      nil ->
        Logger.warning(
          "[AshDispatch.Notifier.CounterHandler] No counter_broadcast_fn configured, skipping broadcast"
        )

      broadcast_fn when is_function(broadcast_fn, 4) ->
        metadata = %{invalidate_queries: invalidates}
        broadcast_fn.(user_id, counter_name, count, metadata: metadata)

      {module, function} when is_atom(module) and is_atom(function) ->
        metadata = %{invalidate_queries: invalidates}
        apply(module, function, [user_id, counter_name, count, [metadata: metadata]])

      other ->
        Logger.error(
          "[AshDispatch.Notifier.CounterHandler] Invalid counter_broadcast_fn config: #{inspect(other)}"
        )
    end
  end
end
