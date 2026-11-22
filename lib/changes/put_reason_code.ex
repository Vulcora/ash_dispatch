defmodule AshDispatch.Changes.PutReasonCode do
  @moduledoc false
  # Writes `content["reason_code"]` beside the `error_message` a receipt is
  # being given: one of `AshDispatch.Reason.codes/0` for a reason the library
  # wrote, `:other` for anything else.
  #
  # Only on a receipt resource built with `reason_codes: true` — see
  # `AshDispatch.Resources.DeliveryReceipt.Base`. Without it the three actions
  # carry no change at all, and `AshDispatch.Reason.of/1` classifies the
  # sentence instead, which needs no column and touches no row.
  #
  # ## Why it is an after_TRANSACTION, and a MERGE
  #
  # The obvious implementation — read `content`, put a key, write it back —
  # writes a whole map that was read a moment earlier, and so undoes anything
  # that landed in between. What lands in between is
  # `AshDispatch.Workers.ScrubSensitiveContent`: a scrub arriving between the
  # retry worker's batch read and its per-receipt update would put the
  # reset-link body back on the row.
  #
  # So the key is merged into whatever the row holds NOW:
  #
  #     update … set content = coalesce(content, '{}'::jsonb) || $1 where id = $2
  #
  # It cannot ride along inside the action's own statement: Ash refuses an
  # atomic update of a `:map` attribute with an expression ("Type
  # `Ash.Type.Map` does not support atomic updates with expressions"). One
  # extra statement, server side, is the honest best available while the code
  # lives in `content`. A column of its own would make it one statement, and a
  # column is a migration, which is 0.10.0 work.
  #
  # And it runs AFTER the transaction, not after the action. An after_action
  # hook runs INSIDE the action's transaction, so a statement that fails there
  # aborts it: every later statement answers "current transaction is aborted"
  # and the COMMIT fails whatever the hook returns. The rescue below claimed
  # to cost only the code and in fact cost the transition — the receipt never
  # got its status. A savepoint would also do, but after_transaction is
  # simpler and says the intention: the receipt's own outcome is already
  # committed and nothing this does can take it back.
  #
  # A data layer that is not AshPostgres — this library's own ETS stand-ins —
  # has no jsonb to merge into and no concurrent scrub to lose to, so there
  # the change writes the attribute as any change would.
  use Ash.Resource.Change

  alias AshDispatch.Reason

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    case code(changeset) do
      nil ->
        changeset

      code ->
        if postgres?(changeset.resource) do
          Ash.Changeset.after_transaction(changeset, fn changeset, result ->
            case result do
              {:ok, record} -> {:ok, merge(record, code, changeset)}
              other -> other
            end
          end)
        else
          content = Ash.Changeset.get_attribute(changeset, :content) || %{}
          Ash.Changeset.change_attribute(changeset, :content, Reason.put_code(content, code))
        end
    end
  end

  defp merge(record, code, changeset) do
    repo = AshPostgres.DataLayer.Info.repo(record.__struct__)
    table = AshPostgres.DataLayer.Info.table(record.__struct__)
    json = Jason.encode!(%{Reason.content_key() => Atom.to_string(code)})

    opts =
      case AshDispatch.Tenancy.receipt_prefix(changeset.tenant) do
        prefix when is_binary(prefix) -> [prefix: prefix]
        _ -> []
      end

    # In a SAVEPOINT, which is what makes the rescue below mean anything. An
    # after_action hook runs inside the action's own transaction, so a
    # statement that fails there aborts the transaction: every later statement
    # answers "current transaction is aborted" and the COMMIT fails whatever
    # this function returns. The rescue claimed to keep the transition and
    # could not. A nested `transaction/2` is a savepoint, so a failed merge
    # rolls back to it and the transition commits without its code.

    # `$1::text::jsonb`, not `$1::jsonb`: with the single cast Postgres infers
    # the parameter's type as jsonb, Postgrex encodes the Elixir string as a
    # jsonb STRING, and `object || "text"` is an array concatenation — the
    # content column came back as `[{...}, "{\"reason_code\":...}"]` and could
    # not even be loaded. Through text it is parsed as an object and `||`
    # merges. (`ScrubSensitiveContent`'s own test support casts the same way.)
    sql =
      "update \"" <>
        table <>
        "\" set \"content\" = coalesce(\"content\", '{}'::jsonb) || $1::text::jsonb " <>
        "where \"id\" = $2"

    # `query/3`, not `query!/3`: a raise inside `transaction/2` rolls back to
    # the savepoint and then propagates, which is the thing being avoided.
    # `rollback/1` returns `{:error, reason}` from the savepoint cleanly and
    # leaves the outer transaction usable.
    # `query/3` rather than `query!/3`: there is nothing left to abort, so a
    # failure is a warning and the record as it stands.
    case repo.query(sql, [json, dump_id(record)], opts) do
      {:ok, _result} ->
        # The record the caller gets back says what the row says.
        %{record | content: Reason.put_code(Map.get(record, :content), code)}

      {:error, reason} ->
        Logger.warning(
          "[AshDispatch] could not store the reason code on receipt " <>
            "#{inspect(Map.get(record, :id))}: #{inspect(reason)}"
        )

        record
    end
  rescue
    error ->
      # A receipt whose reason code could not be stored is still a receipt with
      # the right status and the right sentence, and `Reason.of/1` classifies
      # that. Not worth failing a transition over — and after the transaction
      # there is no transition left to fail.
      Logger.warning(
        "[AshDispatch] could not store the reason code on receipt " <>
          "#{inspect(Map.get(record, :id))}: #{Exception.message(error)}"
      )

      record
  end

  defp dump_id(%{id: id}) when is_binary(id) do
    case Ecto.UUID.dump(id) do
      {:ok, dumped} -> dumped
      :error -> id
    end
  end

  defp dump_id(%{id: id}), do: id

  defp postgres?(resource) do
    Ash.DataLayer.data_layer(resource) == AshPostgres.DataLayer
  rescue
    _ -> false
  end

  # The sentence, from wherever this changeset is carrying it.
  # `fetch_change/2` answers on the ordinary path; on the ATOMIC one — which
  # is what `Ash.update/2` takes by default, through `atomic_upgrade?` — an
  # accepted attribute sits in `changeset.atomics` instead, and reading only
  # the first made this a no-op for every single-receipt update.
  defp code(changeset) do
    case message(changeset) do
      message when is_binary(message) and message != "" -> Reason.classify(message)
      _ -> nil
    end
  end

  defp message(changeset) do
    case Ash.Changeset.fetch_change(changeset, :error_message) do
      {:ok, message} when is_binary(message) ->
        message

      _ ->
        # A literal input is the literal here. An expression (a host computing
        # the message atomically) is not something this can classify, and
        # `nil` means no code rather than a guess.
        case Keyword.get(changeset.atomics || [], :error_message) do
          message when is_binary(message) -> message
          _ -> nil
        end
    end
  end
end
