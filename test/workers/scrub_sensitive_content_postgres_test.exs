defmodule AshDispatch.Workers.ScrubSensitiveContentPostgresTest do
  @moduledoc """
  `scrub_query/3` against a real Postgres: its jsonb operators only mean
  anything when they run. Needs `ASH_DISPATCH_TEST_DATABASE_URL` (the CI job
  starts a postgres service); `test_helper.exs` excludes the tag without it.
  """
  use ExUnit.Case, async: false

  alias AshDispatch.Workers.ScrubSensitiveContent

  @moduletag :postgres

  @table "scrub_test_receipts"
  @event "ticket.otp_issued"
  @marker ScrubSensitiveContent.marker()

  defmodule Repo do
    use Ecto.Repo, otp_app: :ash_dispatch, adapter: Ecto.Adapters.Postgres
  end

  setup do
    # one connection, so the temporary table is visible to every query
    start_supervised!(
      {Repo, url: System.fetch_env!("ASH_DISPATCH_TEST_DATABASE_URL"), pool_size: 1}
    )

    Repo.query!("""
    create temporary table #{@table} (
      id integer primary key,
      event_id text not null,
      status text not null,
      body_text text,
      body_html text,
      content jsonb not null default '{}',
      inserted_at timestamptz not null
    )
    """)

    :ok
  end

  defp receipt!(id, attrs \\ []) do
    row =
      Keyword.merge(
        [
          event_id: @event,
          status: "sent",
          body_text: "Reset: token",
          body_html: "<a>token</a>",
          content:
            ~s({"subject": "Your code", "html_body": "<a>token</a>", "text_body": "Reset: token"}),
          inserted_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        ],
        attrs
      )

    Repo.query!(
      "insert into #{@table} (id, event_id, status, body_text, body_html, content, inserted_at) " <>
        "values ($1, $2, $3, $4, $5, $6::text::jsonb, $7)",
      [
        id,
        row[:event_id],
        row[:status],
        row[:body_text],
        row[:body_html],
        row[:content],
        row[:inserted_at]
      ]
    )
  end

  defp scrub do
    @table
    |> ScrubSensitiveContent.scrub_query(
      [@event],
      DateTime.utc_now(),
      DateTime.add(DateTime.utc_now(), -86_400, :second)
    )
    |> Repo.update_all([])
    |> elem(0)
  end

  defp row(id) do
    %{rows: [[text, html, content]]} =
      Repo.query!("select body_text, body_html, content from #{@table} where id = $1", [id])

    {text, html, content}
  end

  test "empties both bodies and the copies in content, and leaves the rest of it" do
    receipt!(1)

    assert scrub() == 1
    assert {@marker, nil, %{"subject" => "Your code"} = content} = row(1)
    refute Map.has_key?(content, "html_body")
    refute Map.has_key?(content, "text_body")
  end

  test "every terminal status is scrubbed" do
    for {status, id} <- Enum.with_index(~w(sent skipped failed_permanent), 1) do
      receipt!(id, status: status)
    end

    assert scrub() == 3
  end

  test "a receipt that can still be sent is never scrubbed" do
    statuses = ~w(pending scheduled sending failed)

    for {status, id} <- Enum.with_index(statuses, 1), do: receipt!(id, status: status)

    assert scrub() == 0

    for id <- 1..length(statuses) do
      assert {"Reset: token", "<a>token</a>", %{"html_body" => _}} = row(id)
    end
  end

  test "a stranded receipt is scrubbed past the cap, whatever its status" do
    gammal = DateTime.add(DateTime.utc_now(), -2 * 86_400, :second)
    statuses = ~w(pending scheduled sending failed)

    for {status, id} <- Enum.with_index(statuses, 1) do
      receipt!(id, status: status, inserted_at: gammal)
    end

    assert scrub() == 4

    for id <- 1..length(statuses) do
      assert {@marker, nil, content} = row(id)
      refute Map.has_key?(content, "html_body")
    end
  end

  test "a sensitive SMS loses its text from the content" do
    receipt!(1,
      body_text: nil,
      body_html: nil,
      content: ~s({"message": "Your code is 123456", "body": "123456", "recipient_name": "A"})
    )

    assert scrub() == 1
    assert {@marker, nil, content} = row(1)
    assert content == %{"recipient_name" => "A"}
  end

  test "a sensitive Slack receipt loses both copies of its text" do
    # Slack and Discord carry the body TWICE in `content`: under `message`,
    # which `AshDispatch.Preview` renders from, and under
    # `notification_message`, which the transport reads for the payload's
    # `"text"`. A scrub that knew only the first left the second in the
    # database for good — the whole point of the window is that neither stays.
    receipt!(1,
      body_text: nil,
      body_html: nil,
      content: ~s({
        "message": "Your code is 123456",
        "notification_message": "Your code is 123456",
        "transport": "slack"
      })
    )

    assert scrub() == 1
    assert {@marker, nil, content} = row(1)
    refute Map.has_key?(content, "message")
    refute Map.has_key?(content, "notification_message")
    assert content == %{"transport" => "slack"}
  end

  test "picks up a receipt whose only remaining copy is notification_message" do
    # What a receipt scrubbed by a version that did not know the key looks
    # like: `message` gone, `notification_message` left behind. The where
    # clause has to name it too, or nothing ever revisits that row and the
    # text stays past every window.
    receipt!(1,
      body_text: @marker,
      body_html: nil,
      content: ~s({"notification_message": "Your code is 123456"})
    )

    assert scrub() == 1
    assert {@marker, nil, content} = row(1)
    assert content == %{}
  end

  test "picks up a receipt scrubbed before 0.8.7, whose content still holds a body" do
    receipt!(1, body_text: @marker, body_html: nil)

    assert scrub() == 1
    assert {@marker, nil, content} = row(1)
    refute Map.has_key?(content, "html_body")
  end

  test "an already scrubbed receipt is not touched again" do
    receipt!(1, body_text: @marker, body_html: nil, content: ~s({"subject": "Your code"}))

    assert scrub() == 0
  end

  test "another event and a receipt inside the window are left alone" do
    receipt!(1, event_id: "ticket.created")
    receipt!(2, inserted_at: DateTime.add(DateTime.utc_now(), 3600, :second))

    assert scrub() == 0
  end
end
