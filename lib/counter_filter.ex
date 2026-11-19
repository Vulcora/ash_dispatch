defmodule AshDispatch.CounterFilter do
  @moduledoc false
  # A counter's `query_filter`, applied to a query — the one implementation
  # `AshDispatch.Notifier.CounterHandler` (the broadcast after a change) and
  # `AshDispatch.Helpers.CounterLoader` (the count a page starts with) share.
  # They were two copies; a count that differs between the first render and
  # the first update is the bug two copies grow.
  #
  # A keyword list is ANDed: a list value means `in`, `nil` means `is_nil`,
  # anything else means `==`. `nil` is the case the copies got wrong: Ash
  # compares with `nil` the way SQL does, so `field == nil` is never true, and
  # `Notification.Base`'s `unread_notifications` counter
  # (`query_filter: [read: false, archived_at: nil]`) counted 0 for everyone
  # from 0.9.0 on.
  #
  # Any other filter (an `expr/1`) is passed to `Ash.Query.filter/2` as it is.

  require Ash.Query
  import Ash.Expr

  require Logger

  @spec apply(Ash.Query.t(), term()) :: Ash.Query.t()
  def apply(query, nil), do: query
  def apply(query, []), do: query

  def apply(query, query_filter) when is_list(query_filter) do
    if Keyword.keyword?(query_filter) do
      Enum.reduce(query_filter, query, fn
        {field, nil}, acc -> Ash.Query.filter(acc, is_nil(^ref(field)))
        {field, value}, acc when is_list(value) -> Ash.Query.filter(acc, ^ref(field) in ^value)
        {field, value}, acc -> Ash.Query.filter(acc, ^ref(field) == ^value)
      end)
    else
      Logger.warning(
        "[AshDispatch] Unknown counter query_filter format (non-keyword list): #{inspect(query_filter)}"
      )

      query
    end
  end

  def apply(query, query_filter), do: Ash.Query.filter(query, ^query_filter)
end
