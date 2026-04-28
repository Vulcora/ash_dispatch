defmodule AshDispatch.Helpers.RecordReader do
  @moduledoc """
  Defensive field-reading helpers for post-action notifier hooks.

  ## Why this exists

  Ash actions can use narrowed `select` clauses to return only a subset
  of attributes. The excluded attributes are populated as
  `%Ash.NotLoaded{}` sentinels rather than raising or returning `nil`.

  Notifier hooks (counter broadcasts, locale extraction, dispatch
  context building) read fields off the action's resulting record to
  decide what to do next. A bare `Map.get(record, field)` returns the
  sentinel for narrowed fields, which then cascades into:

  - `Ecto.Query.CastError` when used in a query filter
  - `ArgumentError "Actor field is not loaded"` from
    `Ash.Query.relates_to_actor_via` checks
  - `Protocol.UndefinedError{protocol: String.Chars}` when interpolated
    into a topic string or log message
  - Truthy-check bugs: `if Map.get(record, :foo)` is `true` for a
    sentinel because it's a struct, not nil/false

  ## The contract

  Notifier side effects are best-effort — they must degrade silently
  when the record can't yield the field, not crash the request or
  spam the log. These helpers treat `%Ash.NotLoaded{}` as `nil` so
  callers' existing nil-checks make the right decision automatically.

  Single debug log per call so production diagnostics are still
  available without polluting test output.
  """

  require Logger

  @doc """
  Like `Map.get/2` but treats `%Ash.NotLoaded{}` as `nil`.

  Emits a single debug-level log line when the sentinel is observed,
  to aid diagnosing select-narrowed actions in production.
  """
  @spec safe_get(map(), atom() | String.t()) :: term() | nil
  def safe_get(record, field) do
    case Map.get(record, field) do
      %Ash.NotLoaded{} ->
        Logger.debug(fn ->
          struct_name =
            case record do
              %{__struct__: mod} -> inspect(mod)
              _ -> "record"
            end

          "[AshDispatch] field #{inspect(field)} not loaded on #{struct_name}; " <>
            "treating as nil (action likely used a narrowed select)."
        end)

        nil

      other ->
        other
    end
  end

  @doc """
  `safe_get/2` with a default returned when the field is `nil` or
  `%Ash.NotLoaded{}`.
  """
  @spec safe_get(map(), atom() | String.t(), term()) :: term()
  def safe_get(record, field, default) do
    case safe_get(record, field) do
      nil -> default
      val -> val
    end
  end

  @doc """
  Returns `true` if the field is present on the record AND has been
  loaded (i.e. is not the `%Ash.NotLoaded{}` sentinel).
  """
  @spec loaded?(map(), atom() | String.t()) :: boolean()
  def loaded?(record, field) do
    case Map.get(record, field, :__missing__) do
      :__missing__ -> false
      %Ash.NotLoaded{} -> false
      _ -> true
    end
  end
end
