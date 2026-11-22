defmodule AshDispatch.Workers.PrunePostgresTest do
  @moduledoc """
  `AshDispatch.Workers.Prune`'s three queries against a real Postgres: the
  jsonb operators and the batching subquery only mean anything when they run.
  Needs `ASH_DISPATCH_TEST_DATABASE_URL` (the CI job starts a postgres
  service); `test_helper.exs` excludes the tag without it.
  """
  use ExUnit.Case, async: false

  alias AshDispatch.Workers.Prune

  @moduletag :postgres

  @receipts "prune_test_receipts"
  @notifications "prune_test_notifications"
  @marker Prune.marker()

  defmodule Repo do
    use Ecto.Repo, otp_app: :ash_dispatch, adapter: Ecto.Adapters.Postgres
  end

  setup do
    # One connection, so the temporary tables are visible to every query.
    start_supervised!(
      {Repo, url: System.fetch_env!("ASH_DISPATCH_TEST_DATABASE_URL"), pool_size: 1}
    )

    Repo.query!("""
    create temporary table #{@receipts} (
      id integer primary key,
      status text not null,
      body_text text,
      body_html text,
      content jsonb not null default '{}',
      inserted_at timestamptz not null
    )
    """)

    Repo.query!("""
    create temporary table #{@notifications} (
      id integer primary key,
      occurred_at timestamptz,
      inserted_at timestamptz not null
    )
    """)

    :ok
  end

  defp ago(hours), do: DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

  defp receipt!(id, attrs \\ []) do
    row =
      Keyword.merge(
        [
          status: "sent",
          body_text: "Dear Alva",
          body_html: "<p>Dear Alva</p>",
          content: ~s({"subject": "Your order", "html_body": "<p>x</p>", "text_body": "x"}),
          inserted_at: ago(100)
        ],
        attrs
      )

    Repo.query!(
      "insert into #{@receipts} (id, status, body_text, body_html, content, inserted_at) " <>
        "values ($1, $2, $3, $4, $5::text::jsonb, $6)",
      [id, row[:status], row[:body_text], row[:body_html], row[:content], row[:inserted_at]]
    )
  end

  defp notification!(id, attrs \\ []) do
    row = Keyword.merge([occurred_at: ago(100), inserted_at: ago(100)], attrs)

    Repo.query!(
      "insert into #{@notifications} (id, occurred_at, inserted_at) values ($1, $2, $3)",
      [id, row[:occurred_at], row[:inserted_at]]
    )
  end

  defp read(id) do
    %{rows: rows} =
      Repo.query!(
        "select body_text, body_html, content from #{@receipts} where id = $1",
        [id]
      )

    case rows do
      [[body_text, body_html, content]] -> %{text: body_text, html: body_html, content: content}
      [] -> nil
    end
  end

  defp ids(table) do
    %{rows: rows} = Repo.query!("select id from #{table} order by id")
    List.flatten(rows)
  end

  defp empty_bodies(hours) do
    @receipts |> Prune.body_query(ago(hours)) |> Repo.update_all([]) |> elem(0)
  end

  defp delete_receipts(hours) do
    @receipts |> Prune.receipt_query(ago(hours)) |> Repo.delete_all() |> elem(0)
  end

  defp delete_notifications(hours) do
    @notifications |> Prune.notification_query(ago(hours)) |> Repo.delete_all() |> elem(0)
  end

  describe "the body pass" do
    test "empties both columns and the copies in content" do
      receipt!(1)

      assert empty_bodies(24) == 1

      assert read(1) == %{
               text: @marker,
               html: nil,
               content: %{"subject" => "Your order"}
             }
    end

    test "removes an SMS's text, which lives only in content" do
      receipt!(1, body_text: nil, body_html: nil, content: ~s({"message": "Code 1234"}))

      assert empty_bodies(24) == 1
      assert read(1).content == %{}
    end

    test "leaves a receipt inside the window alone" do
      receipt!(1, inserted_at: ago(1))

      assert empty_bodies(24) == 0
      assert read(1).text == "Dear Alva"
    end

    test "leaves a receipt that is not terminal alone, because it may still be sent" do
      for {id, status} <- [{1, "pending"}, {2, "scheduled"}, {3, "sending"}, {4, "failed"}] do
        receipt!(id, status: status)
      end

      assert empty_bodies(24) == 0
    end

    test "touches every terminal status" do
      for {id, status} <- [
            {1, "sent"},
            {2, "skipped"},
            {3, "failed_permanent"},
            {4, "digested"}
          ] do
        receipt!(id, status: status)
      end

      assert empty_bodies(24) == 4
    end

    test "is idempotent: an already emptied receipt is not picked up again" do
      receipt!(1)

      assert empty_bodies(24) == 1
      assert empty_bodies(24) == 0
    end

    test "never deletes the row — the receipt is the audit trail" do
      receipt!(1)

      empty_bodies(24)

      assert ids(@receipts) == [1]
    end
  end

  describe "the receipt pass" do
    test "deletes a terminal receipt past the window" do
      receipt!(1)
      receipt!(2, inserted_at: ago(1))

      assert delete_receipts(24) == 1
      assert ids(@receipts) == [2]
    end

    test "leaves a receipt that is not terminal, however old" do
      receipt!(1, status: "scheduled", inserted_at: ago(10_000))

      assert delete_receipts(24) == 0
      assert ids(@receipts) == [1]
    end
  end

  describe "the notification pass" do
    test "deletes by occurred_at" do
      notification!(1)
      notification!(2, occurred_at: ago(1), inserted_at: ago(1))

      assert delete_notifications(24) == 1
      assert ids(@notifications) == [2]
    end

    test "falls back on inserted_at when occurred_at is null" do
      notification!(1, occurred_at: nil)
      notification!(2, occurred_at: nil, inserted_at: ago(1))

      assert delete_notifications(24) == 1
      assert ids(@notifications) == [2]
    end
  end

  describe "the batch" do
    setup do
      previous = Application.fetch_env(:ash_dispatch, :prune_batch_size)
      Application.put_env(:ash_dispatch, :prune_batch_size, 2)

      on_exit(fn ->
        case previous do
          {:ok, old} -> Application.put_env(:ash_dispatch, :prune_batch_size, old)
          :error -> Application.delete_env(:ash_dispatch, :prune_batch_size)
        end
      end)

      :ok
    end

    test "caps one pass, so a large table is not locked for minutes" do
      for id <- 1..5, do: receipt!(id)

      assert delete_receipts(24) == 2
      assert delete_receipts(24) == 2
      assert delete_receipts(24) == 1
      assert delete_receipts(24) == 0
    end

    test "caps the body pass too" do
      for id <- 1..5, do: receipt!(id)

      assert empty_bodies(24) == 2
      assert empty_bodies(24) == 2
      assert empty_bodies(24) == 1
    end
  end
end
