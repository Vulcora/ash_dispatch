defmodule AshDispatch.Calculations.LoadUserTest do
  use ExUnit.Case, async: true

  alias AshDispatch.Calculations.LoadUser

  describe "LoadUser calculation" do
    test "returns empty list when no user resource is configured" do
      # Temporarily remove user_resource config
      original_user_resource = Application.get_env(:ash_dispatch, :user_resource)
      original_user_domain = Application.get_env(:ash_dispatch, :user_domain)

      Application.delete_env(:ash_dispatch, :user_resource)
      Application.delete_env(:ash_dispatch, :user_domain)

      # Mock records
      records = [
        %{user_id: "user-1"},
        %{user_id: "user-2"},
        %{user_id: nil}
      ]

      result = LoadUser.calculate(records, [], %{})

      # Should return nil for all records when no config
      assert result == [nil, nil, nil]

      # Restore config
      if original_user_resource do
        Application.put_env(:ash_dispatch, :user_resource, original_user_resource)
      end

      if original_user_domain do
        Application.put_env(:ash_dispatch, :user_domain, original_user_domain)
      end
    end

    test "declares user_id as required field" do
      assert LoadUser.load(nil, [], nil) == [:user_id]
    end
  end
end
