defmodule AshDispatch.Test.Ets do
  @moduledoc """
  Empties a public ETS-backed resource between tests, and waits until it is
  empty.

  `Ash.DataLayer.Ets.stop/1` ends the table's owner with
  `Process.exit(pid, :shutdown)` and returns at once; the table is deleted
  when the owner has actually died. A test that writes in that gap writes to
  the old table, which disappears under it a moment later: a preference row
  that is never read, a notification that is never counted. `stop/1`
  monitors the owner and returns only after it is gone, so the next test
  starts on a fresh table.
  """

  @doc "Stops `resource`'s ETS table and returns once it is gone."
  @spec stop(Ash.Resource.t()) :: :ok
  def stop(resource) do
    with {:ok, table} <- Ash.DataLayer.Ets.table_name(resource, nil, false),
         owner when is_pid(owner) <- owner(table) do
      ref = Process.monitor(owner)
      Ash.DataLayer.Ets.stop(resource)

      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      after
        5_000 ->
          raise "the ETS table of #{inspect(resource)} was still alive 5 s after stop"
      end
    else
      _ ->
        # No table yet, or a private one (owned by the test process).
        Ash.DataLayer.Ets.stop(resource)
        :ok
    end
  end

  defp owner(table) when is_atom(table) do
    case :ets.whereis(table) do
      :undefined -> nil
      _ref -> :ets.info(table, :owner)
    end
  end

  defp owner(_table), do: nil
end
