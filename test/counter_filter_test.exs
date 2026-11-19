defmodule AshDispatch.CounterFilterTest do
  @moduledoc """
  A counter's `query_filter`, as the broadcast and the first render apply it.

  `nil` in a keyword filter used to become `field == nil`, which Ash — like
  SQL — never finds true, so `Notification.Base`'s `unread_notifications`
  counter (`archived_at: nil`) counted nothing from 0.9.0 on.
  """
  use ExUnit.Case, async: false

  alias AshDispatch.CounterFilter
  alias AshDispatch.Test.CounterTestResource, as: Resource

  setup do
    on_exit(fn -> AshDispatch.Test.Ets.stop(Resource) end)

    for {status, deleted_at} <- [
          {:pending, nil},
          {:pending, nil},
          {:pending, ~U[2026-11-18 12:00:00Z]},
          {:active, nil}
        ] do
      Ash.Seed.seed!(Resource, %{status: status, deleted_at: deleted_at})
    end

    :ok
  end

  defp count(filter), do: Resource |> CounterFilter.apply(filter) |> Ash.count!(authorize?: false)

  test "nil means is_nil" do
    assert count(deleted_at: nil) == 3
    assert count(status: :pending, deleted_at: nil) == 2
  end

  test "the spelling it replaces, == nil, counts nothing" do
    require Ash.Query
    import Ash.Expr

    field = :deleted_at

    assert Resource
           |> Ash.Query.filter(^ref(field) == ^nil)
           |> Ash.count!(authorize?: false) == 0
  end

  test "a list means in, a value means equal" do
    assert count(status: [:pending, :active]) == 4
    assert count(status: :active) == 1
  end

  test "no filter counts everything" do
    assert count(nil) == 4
    assert count([]) == 4
  end

  test "an expression is applied as it is" do
    require Ash.Expr
    assert count(Ash.Expr.expr(not is_nil(deleted_at))) == 1
  end
end
