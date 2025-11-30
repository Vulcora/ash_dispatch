defmodule AshDispatch.Helpers.ResourceIntrospectionTest do
  @moduledoc """
  Tests for ResourceIntrospection helper functions.

  These tests verify the introspection capabilities used for counter
  broadcasting and user relationship derivation.
  """

  use ExUnit.Case, async: false

  alias AshDispatch.Helpers.ResourceIntrospection

  # Store original config to restore after tests
  setup do
    original_audiences = Application.get_env(:ash_dispatch, :audiences)
    original_user_module = Application.get_env(:ash_dispatch, :user_module)

    on_exit(fn ->
      if original_audiences do
        Application.put_env(:ash_dispatch, :audiences, original_audiences)
      else
        Application.delete_env(:ash_dispatch, :audiences)
      end

      if original_user_module do
        Application.put_env(:ash_dispatch, :user_module, original_user_module)
      else
        Application.delete_env(:ash_dispatch, :user_module)
      end
    end)

    :ok
  end

  describe "is_relationship_audience?/1" do
    test "returns true for bare atom audiences" do
      Application.put_env(:ash_dispatch, :audiences, [
        :user,
        :partner,
        {:admin, [:user, {:admin, true}]}
      ])

      assert ResourceIntrospection.is_relationship_audience?(:user) == true
      assert ResourceIntrospection.is_relationship_audience?(:partner) == true
    end

    test "returns false for filter-based audiences (tuples)" do
      Application.put_env(:ash_dispatch, :audiences, [
        :user,
        {:admin, [:user, {:admin, true}]},
        {:super_admin, [:user, {:super_admin, true}]}
      ])

      assert ResourceIntrospection.is_relationship_audience?(:admin) == false
      assert ResourceIntrospection.is_relationship_audience?(:super_admin) == false
    end

    test "returns true for unknown audiences (backward compatibility)" do
      Application.put_env(:ash_dispatch, :audiences, [:user])

      # Unknown audiences default to relationship-based for backward compat
      assert ResourceIntrospection.is_relationship_audience?(:custom) == true
      assert ResourceIntrospection.is_relationship_audience?(:unknown) == true
    end

    test "handles empty config" do
      Application.put_env(:ash_dispatch, :audiences, [])

      # With empty config, assumes relationship-based
      assert ResourceIntrospection.is_relationship_audience?(:user) == true
    end
  end

  describe "get_audience_relationship/1" do
    test "returns audience name for bare atom audiences" do
      Application.put_env(:ash_dispatch, :audiences, [
        :user,
        :partner,
        {:admin, [:user, {:admin, true}]}
      ])

      assert ResourceIntrospection.get_audience_relationship(:user) == :user
      assert ResourceIntrospection.get_audience_relationship(:partner) == :partner
    end

    test "extracts first atom from filter-based audience config" do
      Application.put_env(:ash_dispatch, :audiences, [
        :user,
        {:admin, [:user, {:admin, true}]},
        {:seller, [:partner, {:role, :seller}]}
      ])

      # :admin config is [:user, {:admin, true}], so relationship is :user
      assert ResourceIntrospection.get_audience_relationship(:admin) == :user
      # :seller config is [:partner, {:role, :seller}], so relationship is :partner
      assert ResourceIntrospection.get_audience_relationship(:seller) == :partner
    end

    test "returns nil for unknown audiences not in config" do
      Application.put_env(:ash_dispatch, :audiences, [:user])

      # Unknown audiences return nil (not in config as tuple)
      assert ResourceIntrospection.get_audience_relationship(:unknown) == nil
    end
  end

  describe "build_user_filter/2" do
    test "builds simple filter for single-element path" do
      assert ResourceIntrospection.build_user_filter([:user_id], "user-123") ==
               [user_id: "user-123"]
    end

    test "builds nested filter for two-element path" do
      assert ResourceIntrospection.build_user_filter([:cart, :user_id], "user-123") ==
               [cart: [user_id: "user-123"]]
    end

    test "builds deeply nested filter for longer paths" do
      assert ResourceIntrospection.build_user_filter([:order, :cart, :user_id], "user-123") ==
               [order: [cart: [user_id: "user-123"]]]
    end

    test "handles various user_id types" do
      uuid = "550e8400-e29b-41d4-a716-446655440000"
      assert ResourceIntrospection.build_user_filter([:user_id], uuid) == [user_id: uuid]

      # Integer IDs
      assert ResourceIntrospection.build_user_filter([:user_id], 123) == [user_id: 123]
    end
  end

  describe "derive_user_id_path/1 and derive_user_id_path/2" do
    # These tests require a mock resource with user relationships
    # We test the logic indirectly through the behavior

    test "returns nil when user_module is not configured" do
      Application.delete_env(:ash_dispatch, :user_module)

      # With no user_module, can't derive path
      # Using a non-existent module to test the nil case
      assert ResourceIntrospection.derive_user_id_path(NonExistentModule) == nil
    end

    test "derive_user_id_path/2 returns nil when user_module is not configured" do
      Application.delete_env(:ash_dispatch, :user_module)

      assert ResourceIntrospection.derive_user_id_path(NonExistentModule, :user) == nil
    end

    test "1-arity version delegates to 2-arity with nil audience" do
      Application.delete_env(:ash_dispatch, :user_module)

      # Both should return nil when user_module not configured
      assert ResourceIntrospection.derive_user_id_path(NonExistentModule) ==
               ResourceIntrospection.derive_user_id_path(NonExistentModule, nil)
    end
  end

  describe "find_user_relationships/1" do
    test "returns empty list when user_module is not configured" do
      Application.delete_env(:ash_dispatch, :user_module)

      assert ResourceIntrospection.find_user_relationships(SomeModule) == []
    end
  end

  describe "has_user_relationship?/1" do
    test "returns false when user_module is not configured" do
      Application.delete_env(:ash_dispatch, :user_module)

      assert ResourceIntrospection.has_user_relationship?(SomeModule) == false
    end
  end

  describe "parse_audience_config/1" do
    test "parses new format with relationship path and filter" do
      config = [:user, {:admin, true}]
      assert ResourceIntrospection.parse_audience_config(config) == {[:user], [admin: true]}
    end

    test "parses relationship chain without filter" do
      config = [:user, :associated_seller]

      assert ResourceIntrospection.parse_audience_config(config) ==
               {[:user, :associated_seller], []}
    end

    test "parses legacy format (filter only)" do
      config = [{:admin, true}]
      assert ResourceIntrospection.parse_audience_config(config) == {[], [admin: true]}
    end

    test "handles empty config" do
      assert ResourceIntrospection.parse_audience_config([]) == {[], []}
    end

    test "handles multiple filters" do
      config = [:user, {:admin, true}, {:region, :eu}]

      assert ResourceIntrospection.parse_audience_config(config) ==
               {[:user], [admin: true, region: :eu]}
    end

    test "handles non-list input" do
      assert ResourceIntrospection.parse_audience_config(nil) == {[], []}
      assert ResourceIntrospection.parse_audience_config(:atom) == {[], []}
    end
  end

  describe "extract_audience_filter/1" do
    test "extracts filter from config with relationship path" do
      config = [:user, {:admin, true}]
      assert ResourceIntrospection.extract_audience_filter(config) == [admin: true]
    end

    test "extracts filter from legacy format" do
      config = [{:admin, true}, {:role, :support}]

      assert ResourceIntrospection.extract_audience_filter(config) == [
               admin: true,
               role: :support
             ]
    end

    test "returns empty list when no filter" do
      assert ResourceIntrospection.extract_audience_filter([:user]) == []
      assert ResourceIntrospection.extract_audience_filter([]) == []
    end
  end
end
