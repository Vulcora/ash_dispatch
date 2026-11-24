defmodule AshDispatch.DoctorTest do
  @moduledoc """
  The half of the `uuid_generate_v7()` check that asks the database (#50).

  rc.2 warned from the repo's source. The first per-tenant host's source said
  `"ash-functions"` and the function was missing anyway, because ash_postgres
  emits it only when it is not relying on the server's own — which it derives
  from `min_pg_version/0` — and that migration had been generated while the
  answer was 18. No reading of the project's files can settle that. This can.

  Most of what is pinned here uses a repo stub rather than a database: what the
  Doctor must get right is *which* function it asks for and what it says when
  the answer is no, and both are decisions, not queries. The one `:postgres`
  test proves the query itself runs against a real server.
  """
  # Not async: the `:postgres` half starts `AshDispatch.Test.PerTenant.Repo`,
  # which is a named process the tenancy suite starts too.
  use ExUnit.Case, async: false

  alias AshDispatch.Doctor

  # A resource with a UUID v7 primary key (`&Ash.UUIDv7.generate/0`), which is
  # the exact default ash_postgres turns into `fragment("uuid_generate_v7()")`.
  @v7 AshDispatch.Test.PerTenant.Notification

  # The same base with `primary_key: :uuid`: `gen_random_uuid()`, built in.
  @v4 AshDispatch.Test.PrimaryKey.Notification

  defmodule Repo.Fine do
    @moduledoc false
    def use_builtin_uuidv7_function?, do: false

    def query("SELECT to_regprocedure" <> _, _params), do: {:ok, %{rows: [[true]]}}
    def query(_sql, _params), do: {:ok, %{rows: []}}
  end

  defmodule Repo.Missing do
    @moduledoc false
    def use_builtin_uuidv7_function?, do: false

    def query("SELECT to_regprocedure" <> _, _params), do: {:ok, %{rows: [[false]]}}
    def query(_sql, _params), do: {:ok, %{rows: []}}
  end

  defmodule Repo.WrongSchema do
    @moduledoc false
    def use_builtin_uuidv7_function?, do: false

    def query("SELECT to_regprocedure" <> _, _params), do: {:ok, %{rows: [[false]]}}
    def query("SELECT current_setting" <> _, _params), do: {:ok, %{rows: [["\"$user\""]]}}

    def query(sql, _params) do
      if String.contains?(sql, "pg_proc") do
        {:ok, %{rows: [["ash_shared"]]}}
      else
        {:ok, %{rows: []}}
      end
    end
  end

  defmodule Repo.Builtin do
    @moduledoc false
    # `min_pg_version/0` answers 18 or more, so ash_postgres writes `uuidv7()`
    # as the column default and creates nothing — and this server is older.
    def use_builtin_uuidv7_function?, do: true

    def query("SELECT to_regprocedure" <> _, _params), do: {:ok, %{rows: [[false]]}}
    def query(_sql, _params), do: {:ok, %{rows: []}}
  end

  defmodule Repo.TableSaysOtherwise do
    @moduledoc false
    # The repo now answers 18, so the NEXT migration would use the builtin,
    # which this server has. The table was created while the answer was lower,
    # so its DEFAULT still calls `uuid_generate_v7()` — and that is missing.
    # Only reading the real column default catches this.
    def use_builtin_uuidv7_function?, do: true

    def query("SELECT to_regprocedure" <> _, ["uuidv7()"]), do: {:ok, %{rows: [[true]]}}
    def query("SELECT to_regprocedure" <> _, _params), do: {:ok, %{rows: [[false]]}}
    def query("SELECT current_setting" <> _, _params), do: {:ok, %{rows: [["public"]]}}

    def query(sql, _params) do
      if String.contains?(sql, "pg_attrdef") do
        {:ok, %{rows: [["public", "uuid_generate_v7()"]]}}
      else
        {:ok, %{rows: []}}
      end
    end
  end

  defmodule Repo.NotStarted do
    @moduledoc false
    def use_builtin_uuidv7_function?, do: false

    def query(_sql, _params) do
      raise RuntimeError, "could not lookup Ecto repo because it was not started"
    end
  end

  describe "which function it asks for" do
    test "a v7 key on a repo that creates the function: nothing wrong" do
      assert Doctor.check_uuid_generate_v7(Repo.Fine, [@v7]) == []
    end

    test "a v4 key asks the database nothing at all" do
      # Not just `:ok` — the point is that `gen_random_uuid()` is built in, so
      # a host that set `primary_key: :uuid` everywhere has nothing to install
      # and must not be told to install it.
      assert Doctor.check_uuid_generate_v7(Repo.Missing, [@v4]) == []
    end

    test "a repo assuming Postgres 18 is asked for uuidv7(), not uuid_generate_v7()" do
      assert [check] = Doctor.check_uuid_generate_v7(Repo.Builtin, [@v7])

      assert check.function == "uuidv7()"
      assert check.detail =~ "only from version 18"
      assert check.detail =~ "OLDEST server you run"
    end

    test "an existing table's own DEFAULT is checked too, not only the repo's rule" do
      assert [check] = Doctor.check_uuid_generate_v7(Repo.TableSaysOtherwise, [@v7])

      assert check.function == "uuid_generate_v7()"
      refute check.detail =~ "only from version 18"
    end
  end

  describe "what it says when the answer is no" do
    test "missing: why it is missing, and the migration to add" do
      assert {:error, error} = Doctor.check(repo: Repo.Missing, resources: [@v7])

      message = Exception.message(error)

      assert message =~ "uuid_generate_v7() does not exist in this database"
      assert message =~ "answers 18 or more"
      assert message =~ "mix ash.codegen install_ash_functions"
      assert message =~ "CREATE OR REPLACE FUNCTION uuid_generate_v7()"
      assert message =~ "primary_key: :uuid"
    end

    test "present but out of reach: the schema, the search_path, and why" do
      assert {:error, error} = Doctor.check(repo: Repo.WrongSchema, resources: [@v7])

      message = Exception.message(error)

      assert message =~ "EXISTS, in ash_shared"
      assert message =~ ~s(search_path is "$user")
      assert message =~ "resolves it against"
      # It must NOT tell a host to install a function it already has.
      refute message =~ "does not exist in this database"
    end

    test "a repo that is not started fails as a check, not as a crash" do
      assert {:error, error} = Doctor.check(repo: Repo.NotStarted, resources: [@v7])

      assert Exception.message(error) =~ "the check itself could not run"
      assert Exception.message(error) =~ "not started"
    end

    test "check!/1 raises the same thing" do
      assert_raise Doctor.Error, ~r/uuid_generate_v7\(\) does not exist/, fn ->
        Doctor.check!(repo: Repo.Missing, resources: [@v7])
      end
    end

    test "the checks are on the exception, for a host that renders its own" do
      assert {:error, %Doctor.Error{checks: [check]}} =
               Doctor.check(repo: Repo.Missing, resources: [@v7])

      assert check.check == :uuid_generate_v7
    end
  end

  describe "no repo" do
    test "says so instead of asking nothing and passing" do
      previous = Application.fetch_env(:ash_dispatch, :repo)
      Application.delete_env(:ash_dispatch, :repo)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:ash_dispatch, :repo, value)
          :error -> Application.delete_env(:ash_dispatch, :repo)
        end
      end)

      assert {:error, error} = Doctor.check()
      assert Exception.message(error) =~ "No repo to ask"
    end
  end

  describe "against a real database" do
    @describetag :postgres

    # The per-tenant fixture installs ash_postgres's own functions, so this is
    # a database in the state a host's `mix ash.migrate` leaves it in. The repo
    # declares `min_pg_version` 15, so the function asked for is
    # `uuid_generate_v7()` on every server the CI matrix runs — the assertion
    # does not depend on which Postgres is answering.
    setup do
      repo = AshDispatch.Test.PerTenant.Repo

      start_supervised!({repo, url: System.fetch_env!("ASH_DISPATCH_TEST_DATABASE_URL")})
      AshDispatch.Test.Schema.install_ash_functions!(repo)

      %{repo: repo}
    end

    test "the query runs, and a migrated database passes", %{repo: repo} do
      assert Doctor.check(repo: repo, resources: [@v7]) == :ok
    end

    test "before any table exists, the repo's own rule decides", %{repo: repo} do
      # `AshDispatch.Test.PrimaryKey.Receipt` is `primary_key: :uuid_v7` on a
      # table nothing creates here, so the column-default half finds nothing
      # and `min_pg_version/0` decides — which is the path a fresh install
      # takes, before the first migration has run.
      assert Doctor.check(repo: repo, resources: [AshDispatch.Test.PrimaryKey.Receipt]) == :ok
    end
  end
end
