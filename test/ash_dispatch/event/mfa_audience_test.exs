defmodule AshDispatch.Event.MfaAudienceTest do
  @moduledoc """
  Tests for MFA (Module/Function/Args) audience resolution in Event.Helpers.

  MFA audiences allow dynamic recipient resolution by calling a function
  that returns either:
  - A list of user structs/maps with :id field
  - A list of user ID strings
  - A keyword filter to query users

  This enables complex patterns like company-wide notifications where
  recipients are determined by business logic rather than static configuration.
  """

  use ExUnit.Case, async: false

  alias AshDispatch.Event.Helpers

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

  # Mock resolver module for testing
  defmodule MockResolver do
    @moduledoc false

    def return_user_maps(_record) do
      [
        %{id: "user-1"},
        %{id: "user-2"},
        %{id: "user-3"}
      ]
    end

    def return_user_ids(_record) do
      ["user-a", "user-b", "user-c"]
    end

    def return_filter(_record) do
      [role: :admin, active: true]
    end

    def return_empty(_record) do
      []
    end

    def uses_resource(nil) do
      [%{id: "fallback-id"}, %{id: "related-user"}]
    end

    def uses_resource(record) when is_map(record) do
      user_id = Map.get(record, :user_id, "fallback-id")
      [%{id: user_id}, %{id: "related-user"}]
    end

    def with_extra_args(record, extra_arg) do
      [%{id: Map.get(record, :user_id, "default")}, %{id: "extra-#{extra_arg}"}]
    end
  end

  describe "resolve_recipients_for_audience/3 with MFA" do
    test "resolves MFA that returns list of user maps" do
      Application.put_env(:ash_dispatch, :audiences,
        company_members: {MockResolver, :return_user_maps, [:resource]}
      )

      context = %{data: %{order: %{id: "order-1", user_id: "test-user"}}}
      channel = %{audience: :company_members}

      result = Helpers.resolve_recipients_for_audience(context, channel)

      assert length(result) == 3
      assert %{id: "user-1"} in result
      assert %{id: "user-2"} in result
      assert %{id: "user-3"} in result
    end

    test "resolves MFA that returns list of user IDs" do
      Application.put_env(:ash_dispatch, :audiences,
        id_based_audience: {MockResolver, :return_user_ids, [:resource]}
      )

      context = %{data: %{order: %{id: "order-1"}}}
      channel = %{audience: :id_based_audience}

      result = Helpers.resolve_recipients_for_audience(context, channel)

      assert length(result) == 3
      assert %{id: "user-a"} in result
      assert %{id: "user-b"} in result
      assert %{id: "user-c"} in result
    end

    test "MFA receives the resource from context.data" do
      Application.put_env(:ash_dispatch, :audiences,
        resource_aware: {MockResolver, :uses_resource, [:resource]}
      )

      context = %{data: %{order: %{id: "order-1", user_id: "specific-user-123"}}}
      channel = %{audience: :resource_aware}

      result = Helpers.resolve_recipients_for_audience(context, channel)

      assert length(result) == 2
      # Should have extracted user_id from the record
      assert %{id: "specific-user-123"} in result
      assert %{id: "related-user"} in result
    end

    test "returns empty list when MFA returns empty" do
      Application.put_env(:ash_dispatch, :audiences,
        empty_audience: {MockResolver, :return_empty, [:resource]}
      )

      context = %{data: %{order: %{id: "order-1"}}}
      channel = %{audience: :empty_audience, optional: true}

      result = Helpers.resolve_recipients_for_audience(context, channel)

      assert result == []
    end

    @tag :capture_log
    test "returns empty list when MFA function not found" do
      Application.put_env(:ash_dispatch, :audiences,
        missing_fn: {MockResolver, :nonexistent_function, [:resource]}
      )

      context = %{data: %{order: %{id: "order-1"}}}
      channel = %{audience: :missing_fn}

      result = Helpers.resolve_recipients_for_audience(context, channel)

      assert result == []
    end

    test "handles nil resource gracefully" do
      Application.put_env(:ash_dispatch, :audiences,
        resource_aware: {MockResolver, :uses_resource, [:resource]}
      )

      # Empty context data
      context = %{data: %{}}
      channel = %{audience: :resource_aware}

      result = Helpers.resolve_recipients_for_audience(context, channel)

      # MockResolver.uses_resource returns fallback when user_id is nil
      assert %{id: "fallback-id"} in result
    end
  end

  describe "MFA with multiple arguments" do
    test "passes additional static arguments to MFA function" do
      # Note: Only :resource placeholder is replaced, other args are passed as-is
      Application.put_env(:ash_dispatch, :audiences,
        with_args: {MockResolver, :with_extra_args, [:resource, "static-value"]}
      )

      context = %{data: %{record: %{user_id: "test-user"}}}
      channel = %{audience: :with_args}

      result = Helpers.resolve_recipients_for_audience(context, channel)

      assert %{id: "test-user"} in result
      assert %{id: "extra-static-value"} in result
    end
  end

  describe "MFA vs other audience formats" do
    @tag :capture_log
    test "bare atom audiences still work (relationship extraction)" do
      Application.put_env(:ash_dispatch, :audiences, [:user, :admin])

      # This test verifies MFA doesn't break bare atom handling
      # Bare atoms should be interpreted as relationship names
      context = %{data: %{order: %{id: "order-1"}}}
      channel = %{audience: :user}

      # This will try relationship extraction (which won't find anything in test context)
      # The important thing is it doesn't crash and doesn't call MFA logic
      result = Helpers.resolve_recipients_for_audience(context, channel)

      # Result will be empty since there's no actual :user relationship in test data
      assert is_list(result)
    end

    @tag :capture_log
    test "filter-based audiences still work" do
      # Filter-based (without MFA) should still query users
      Application.put_env(:ash_dispatch, :audiences, admin: [:user, admin: true])

      # Without a real user_module configured, this returns empty
      Application.delete_env(:ash_dispatch, :user_module)

      context = %{data: %{}}
      channel = %{audience: :admin}

      result = Helpers.resolve_recipients_for_audience(context, channel)

      # Returns empty because no user_module configured
      assert result == []
    end
  end

  describe "handle_mfa_result/2 (internal)" do
    # We test this indirectly through resolve_recipients_for_audience
    # but these tests verify the logic paths

    test "wraps string IDs in maps" do
      Application.put_env(:ash_dispatch, :audiences,
        string_ids: {MockResolver, :return_user_ids, [:resource]}
      )

      context = %{data: %{record: %{}}}
      channel = %{audience: :string_ids}

      result = Helpers.resolve_recipients_for_audience(context, channel)

      # String IDs should be wrapped
      assert Enum.all?(result, fn r -> is_map(r) && Map.has_key?(r, :id) end)
    end

    test "passes through user maps unchanged" do
      Application.put_env(:ash_dispatch, :audiences,
        user_maps: {MockResolver, :return_user_maps, [:resource]}
      )

      context = %{data: %{record: %{}}}
      channel = %{audience: :user_maps}

      result = Helpers.resolve_recipients_for_audience(context, channel)

      # Should be the same maps returned by the function
      assert result == [%{id: "user-1"}, %{id: "user-2"}, %{id: "user-3"}]
    end
  end

  describe "MFA audience with counter broadcasting context" do
    test "handles counter-style context (record key)" do
      # Counter broadcasting uses %{data: %{record: record}} format
      Application.put_env(:ash_dispatch, :audiences,
        company_members: {MockResolver, :uses_resource, [:resource]}
      )

      # This is how BroadcastCounterUpdate passes context
      context = %{data: %{record: %{user_id: "order-owner-123", id: "order-id"}}}
      channel = %{audience: :company_members}

      result = Helpers.resolve_recipients_for_audience(context, channel)

      # Should extract user_id from the record
      assert %{id: "order-owner-123"} in result
    end

    test "handles event-style context (named keys)" do
      # Events use %{data: %{order: order}} format
      Application.put_env(:ash_dispatch, :audiences,
        company_members: {MockResolver, :uses_resource, [:resource]}
      )

      # This is how events pass context - single key to avoid map ordering issues
      context = %{data: %{order: %{user_id: "event-user-456", id: "order-id"}}}
      channel = %{audience: :company_members}

      result = Helpers.resolve_recipients_for_audience(context, channel)

      # extract_primary_resource gets the order
      assert %{id: "event-user-456"} in result
      assert %{id: "related-user"} in result
    end
  end
end
