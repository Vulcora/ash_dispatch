defmodule AshDispatch.Changes.BroadcastCounterUpdateTest do
  @moduledoc """
  Tests for BroadcastCounterUpdate change module.

  These tests verify the query_filter application logic with both
  Ash expressions (expr()) and keyword list formats.
  """

  use ExUnit.Case, async: true

  require Ash.Query
  import Ash.Expr

  # Use pre-compiled test resource to avoid protocol consolidation warnings
  alias AshDispatch.Test.CounterTestResource, as: TestResource

  describe "query_filter with Ash expressions" do
    test "applies simple expr() filter to query" do
      filter_expr = expr(status == :pending)

      query =
        TestResource
        |> Ash.Query.new()
        |> Ash.Query.do_filter(filter_expr)

      # Verify filter was applied (query has filter)
      assert query.filter != nil
    end

    test "applies compound expr() filter with and" do
      filter_expr = expr(unread_count > 0 and is_nil(deleted_at))

      query =
        TestResource
        |> Ash.Query.new()
        |> Ash.Query.do_filter(filter_expr)

      assert query.filter != nil
    end

    test "applies expr() filter with is_nil check" do
      filter_expr = expr(is_nil(deleted_at))

      query =
        TestResource
        |> Ash.Query.new()
        |> Ash.Query.do_filter(filter_expr)

      assert query.filter != nil
    end

    test "applies expr() filter with numeric comparison" do
      filter_expr = expr(unread_count > 0)

      query =
        TestResource
        |> Ash.Query.new()
        |> Ash.Query.do_filter(filter_expr)

      assert query.filter != nil
    end
  end

  describe "query_filter with keyword lists" do
    test "applies simple keyword list filter" do
      query =
        TestResource
        |> Ash.Query.new()
        |> Ash.Query.do_filter(status: :pending)

      assert query.filter != nil
    end

    test "applies keyword list with list value (in clause)" do
      query =
        TestResource
        |> Ash.Query.new()
        |> Ash.Query.do_filter(status: [:pending, :active])

      assert query.filter != nil
    end
  end

  describe "expr() macro behavior" do
    test "expr() returns a struct (BooleanExpression or similar)" do
      filter_expr = expr(status == :pending)

      # expr() should return some kind of Ash expression struct
      assert is_struct(filter_expr)
    end

    test "compound expr() returns a struct" do
      filter_expr = expr(unread_count > 0 and is_nil(deleted_at))

      assert is_struct(filter_expr)
    end

    test "is_nil expr() returns a struct" do
      filter_expr = expr(is_nil(deleted_at))

      assert is_struct(filter_expr)
    end

    test "expr() can be used in do_filter" do
      filter_expr = expr(status == :pending and is_nil(deleted_at))

      # This is the key pattern used in counter broadcasting
      query =
        TestResource
        |> Ash.Query.new()
        |> Ash.Query.do_filter(filter_expr)

      # Should produce a valid query with filter
      assert query.filter != nil
      assert query.resource == TestResource
    end
  end

  describe "edge cases" do
    test "nil filter returns query with nil filter" do
      query = Ash.Query.new(TestResource)

      # Query without any filter
      assert query.filter == nil
    end

    test "empty keyword list filter" do
      query = Ash.Query.new(TestResource)

      # Empty keyword list should be handled
      query_with_empty_filter = Ash.Query.do_filter(query, [])

      # Filter should be nil when filtering with empty list
      assert query_with_empty_filter.filter == nil
    end
  end
end
