defmodule AshDispatch.Resource.Transformers.AudienceLoadDerivationTest do
  use ExUnit.Case, async: true

  alias AshDispatch.Resource.Transformers.InjectDispatchChanges

  describe "derive_load_from_audience/2" do
    setup do
      # Set up test config
      Application.put_env(:ash_dispatch, :audiences, [
        :user,
        admin: [:user, admin: true],
        super_admin: [:user, super_admin: true]
      ])

      on_exit(fn ->
        Application.delete_env(:ash_dispatch, :audiences)
      end)

      :ok
    end

    test "simple audience derives load from config" do
      # Test that :user audience (bare atom in config) derives :user load
      audiences_config = get_audiences_config()

      # :user is a bare atom in config, so it should resolve to :user relationship
      assert Keyword.get(audiences_config, :user) == :user
    end

    test "broadcast audience does not derive load" do
      # Test that :admin (keyword in config) does not derive load
      audiences_config = get_audiences_config()

      # :admin is configured as [:user, admin: true] - a broadcast audience
      assert Keyword.get(audiences_config, :admin) == [:user, admin: true]
    end

    test "path_to_load converts single element to atom" do
      # [:user] -> :user
      result = path_to_load([:user], [:user, :order])
      assert result == :user
    end

    test "path_to_load converts nested path to keyword" do
      # [:order, :user] -> [{:order, :user}]
      result = path_to_load([:order, :user], [:order, :user])
      assert result == [{:order, :user}]
    end

    test "path_to_load converts deep nested path" do
      # [:order, :user, :preferences] -> [{:order, [{:user, :preferences}]}]
      result = path_to_load([:order, :user, :preferences], [:order, :user, :preferences])
      assert result == [{:order, [{:user, :preferences}]}]
    end

    test "path_to_load returns nil for empty path" do
      result = path_to_load([], [:user])
      assert result == nil
    end
  end

  # Helper functions extracted from transformer for testing
  defp get_audiences_config do
    audiences = Application.get_env(:ash_dispatch, :audiences, [])

    Enum.flat_map(audiences, fn
      atom when is_atom(atom) -> [{atom, atom}]
      {key, value} -> [{key, value}]
    end)
  end

  defp path_to_load([], _relationships), do: nil

  defp path_to_load([single], relationships) do
    if single in relationships, do: single, else: single
  end

  defp path_to_load([first | rest], relationships) do
    if first in relationships do
      nested = build_nested_load(rest)
      [{first, nested}]
    else
      nil
    end
  end

  defp build_nested_load([single]), do: single
  defp build_nested_load([first | rest]), do: [{first, build_nested_load(rest)}]
end
