defmodule AshDispatch.Inbox.PostgresTest do
  @moduledoc """
  The preference and notification bases on a real Postgres: the scope
  identity is `NULLS NOT DISTINCT` (a tenant default has `user_id` NULL, and
  must still be one row), and the checker's scope query and the unread
  count only mean something as SQL. Needs `ASH_DISPATCH_TEST_DATABASE_URL`.
  """
  use ExUnit.Case, async: false

  @moduletag :postgres

  defmodule Repo do
    @moduledoc false
    use AshPostgres.Repo, otp_app: :ash_dispatch, warn_on_missing_ash_functions?: false

    def installed_extensions, do: []
    def min_pg_version, do: %Version{major: 15, minor: 0, patch: 0}
  end

  defmodule Preference do
    @moduledoc false
    use AshDispatch.Resources.Preference.Base,
      repo: AshDispatch.Inbox.PostgresTest.Repo,
      domain: AshDispatch.Inbox.PostgresTest.Domain,
      table: "pg_test_preferences"
  end

  defmodule Notification do
    @moduledoc false
    use AshDispatch.Resources.Notification.Base,
      repo: AshDispatch.Inbox.PostgresTest.Repo,
      domain: AshDispatch.Inbox.PostgresTest.Domain,
      table: "pg_test_notifications"
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshDispatch.Inbox.PostgresTest.Preference
      resource AshDispatch.Inbox.PostgresTest.Notification
    end
  end

  alias AshDispatch.UserPreference.Resource

  setup do
    # one connection, so the temporary tables are visible to every query
    start_supervised!(
      {Repo, url: System.fetch_env!("ASH_DISPATCH_TEST_DATABASE_URL"), pool_size: 1}
    )

    Repo.query!("""
    create temporary table pg_test_preferences (
      id uuid primary key,
      tenant text,
      user_id uuid,
      event_id text,
      category text,
      transport text not null,
      enabled boolean not null,
      inserted_at timestamp not null,
      updated_at timestamp not null
    )
    """)

    # What `mix ash.codegen` generates for `nils_distinct?: false`.
    Repo.query!("""
    create unique index pg_test_preferences_unique_scope_index
      on pg_test_preferences (tenant, user_id, event_id, category, transport)
      nulls not distinct
    """)

    Repo.query!("""
    create temporary table pg_test_notifications (
      id uuid primary key,
      user_id uuid not null,
      type text not null,
      title text not null,
      message text not null,
      metadata jsonb not null default '{}',
      action_label text,
      action_url text,
      source text,
      occurred_at timestamp not null,
      read boolean not null default false,
      read_at timestamp,
      event_id text,
      idempotency_key text,
      category text,
      tenant text,
      seen_at timestamp,
      archived_at timestamp,
      inserted_at timestamp not null,
      updated_at timestamp not null
    )
    """)

    previous = Application.fetch_env(:ash_dispatch, :preference_resource)
    Application.put_env(:ash_dispatch, :preference_resource, Preference)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ash_dispatch, :preference_resource, value)
        :error -> Application.delete_env(:ash_dispatch, :preference_resource)
      end
    end)

    :ok
  end

  test "a tenant default is one row however often it is set (NULLS NOT DISTINCT upsert)" do
    for enabled <- [false, true, false] do
      Preference
      |> Ash.Changeset.for_create(:set, %{
        tenant: "org_1",
        category: "meetings",
        transport: :email,
        enabled: enabled
      })
      |> Ash.create!(authorize?: false)
    end

    assert [%{enabled: false, user_id: nil}] = Ash.read!(Preference, authorize?: false)
  end

  test "the scope query: the tenant's defaults and exactly the asked-for users" do
    [anna, bo, cecilia] = for _ <- 1..3, do: Ash.UUID.generate()

    rows = [
      %{tenant: "org_1", category: "meetings", transport: :email, enabled: false},
      %{
        tenant: "org_1",
        user_id: anna,
        event_id: "meeting.updated",
        transport: :email,
        enabled: true
      },
      %{
        tenant: "org_1",
        user_id: cecilia,
        category: "meetings",
        transport: :email,
        enabled: true
      },
      %{tenant: "org_2", user_id: bo, category: "meetings", transport: :email, enabled: true},
      %{tenant: "org_1", user_id: bo, category: "reminders", transport: :email, enabled: true}
    ]

    for row <- rows do
      Preference |> Ash.Changeset.for_create(:set, row) |> Ash.create!(authorize?: false)
    end

    found =
      Preference.for_scope!("org_1", "meeting.updated", "meetings", [anna, bo], authorize?: false)

    assert Enum.map(found, & &1.user_id) |> Enum.sort_by(&to_string/1) ==
             Enum.sort_by([nil, anna], &to_string/1)

    opts = [tenant: "org_1", category: :meetings, event_default: true]
    assert Resource.user_allows?(anna, "meeting.updated", :email, opts)
    refute Resource.user_allows?(bo, "meeting.updated", :email, opts)
    assert Resource.user_allows?(cecilia, "meeting.updated", :email, opts)
  end

  test "unread count and mark_all_as_read in SQL" do
    anna = %{id: Ash.UUID.generate()}

    for i <- 1..3 do
      Notification
      |> Ash.Changeset.for_create(:create, %{
        user_id: anna.id,
        title: "t#{i}",
        message: "m",
        tenant: "org_1",
        category: "meetings"
      })
      |> Ash.create!(authorize?: false)
    end

    assert Notification.unread_count!(actor: anna) == 3
    assert Notification.unread_count!(%{tenant: "org_2"}, actor: anna) == 0

    assert {:ok, _} = Notification.mark_all_as_read(nil, actor: anna)
    assert Notification.unread_count!(actor: anna) == 0
  end
end
