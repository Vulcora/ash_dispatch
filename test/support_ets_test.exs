defmodule AshDispatch.Test.EtsTest do
  @moduledoc """
  `AshDispatch.Test.Ets.stop/1` returns only once the table is gone, so the
  next test never writes into a table that is about to disappear.
  """
  use ExUnit.Case, async: false

  alias AshDispatch.Test.Inbox.Preference

  defp put! do
    Preference
    |> Ash.Changeset.for_create(:set, %{
      tenant: "t",
      category: "c",
      transport: :in_app,
      enabled: false
    })
    |> Ash.create!(authorize?: false)
  end

  defp owner, do: :ets.info(Ash.DataLayer.Ets.Info.table(Preference), :owner)

  test "the table's owner is dead when stop/1 returns" do
    put!()
    old_owner = owner()
    assert is_pid(old_owner)

    # Stopped from another process, as an on_exit callback does it.
    task = Task.async(fn -> AshDispatch.Test.Ets.stop(Preference) end)
    assert :ok = Task.await(task)

    refute Process.alive?(old_owner)

    # A write right after lands in a new table, and stays.
    row = put!()
    assert owner() != old_owner
    assert [%{id: id}] = Ash.read!(Preference, authorize?: false)
    assert id == row.id

    AshDispatch.Test.Ets.stop(Preference)
  end

  test "a resource without a table yet is fine" do
    AshDispatch.Test.Ets.stop(Preference)
    assert :ok = AshDispatch.Test.Ets.stop(Preference)
  end
end
