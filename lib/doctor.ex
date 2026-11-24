defmodule AshDispatch.Doctor do
  @moduledoc """
  Asks the database the questions no source check can answer.

  Everything else the library checks — `mix ash_dispatch.install`'s warnings,
  the `:ash_dispatch` compiler — reads the project's own files. That is free
  and it runs everywhere, and for `uuid_generate_v7()` it is not enough: the
  first per-tenant host had `"ash-functions"` in its repo, the function was
  missing anyway, and only `SELECT to_regprocedure(…)` said so (#50).

  So this module is the opt-in other half. It opens no connection of its own —
  it uses the repo, which must therefore be started — and it is meant to be
  called from exactly two places:

  ## In a test

      test "the database has what ash_dispatch's tables need" do
        assert :ok = AshDispatch.Doctor.check()
      end

  ## At boot

      defmodule MyApp.Application do
        def start(_type, _args) do
          children = [MyApp.Repo, ...]

          with {:ok, pid} <- Supervisor.start_link(children, opts) do
            AshDispatch.Doctor.check!()
            {:ok, pid}
          end
        end
      end

  `check!/1` raises `AshDispatch.Doctor.Error`, whose message carries the
  exact migration to add. Refusing to boot is the right shape for a host that
  creates each tenant's tables when the tenant is created: the alternative is
  a sign-up that fails at `CREATE TABLE`, one tenant at a time.

  `mix ash_dispatch.doctor` runs the same check from the shell.

  ## What it checks

  Only `uuid_generate_v7()`, and only when something needs it. For each
  resource configured as this library's notification, preference or delivery
  receipt resource, the primary key's default is read: Ash's
  `uuid_v7_primary_key` is `&Ash.UUIDv7.generate/0`, which is the exact
  condition ash_postgres matches on when it writes
  `default: fragment("uuid_generate_v7()")` into a migration. A host that
  passed `primary_key: :uuid` to every base needs no function and is told so.

  Which function to ask for is read from the repo the same way ash_postgres
  decides it — `use_builtin_uuidv7_function?/0`, i.e. `min_pg_version/0`'s
  major at 18 or more — so the check is for the function THIS host's
  migrations name, not a guess. Where a table already exists, its real column
  DEFAULT is read out of the catalogue as well, which catches the case the
  repo's current answer no longer describes: a table created while
  `min_pg_version/0` said something else.
  """

  defmodule Error do
    @moduledoc """
    What `AshDispatch.Doctor` found wrong, as an exception.

    `:checks` carries one entry per failed check, for a host that would rather
    render its own message than print `:message`.
    """
    defexception [:message, checks: []]
  end

  alias AshDispatch.Config

  @type check :: %{
          check: atom(),
          function: String.t(),
          detail: String.t()
        }

  @doc """
  Runs every check, or the ones named by `:only`.

  ## Options

  - `:repo` — the repo to ask. Defaults to `config :ash_dispatch, :repo`.
  - `:resources` — the resources whose primary keys decide whether
    `uuid_generate_v7()` is needed. Defaults to the configured notification,
    preference and delivery receipt resources.
  """
  @spec check(keyword()) :: :ok | {:error, Error.t()}
  def check(opts \\ []) do
    repo = opts[:repo] || Config.repo()

    if is_nil(repo) do
      {:error, error([no_repo_check()])}
    else
      case check_uuid_generate_v7(repo, opts[:resources] || default_resources()) do
        [] -> :ok
        checks -> {:error, error(checks)}
      end
    end
  end

  defp no_repo_check do
    %{
      check: :repo,
      function: "",
      detail: """
      No repo to ask. Set one:

          config :ash_dispatch, repo: MyApp.Repo

      or pass it in: `AshDispatch.Doctor.check(repo: MyApp.Repo)`.
      """
    }
  end

  @doc """
  `check/1`, raising `AshDispatch.Doctor.Error` instead of returning it.
  """
  @spec check!(keyword()) :: :ok
  def check!(opts \\ []) do
    case check(opts) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end

  # ============================================================================
  # uuid_generate_v7()
  # ============================================================================

  @doc false
  # The functions the host's own migrations name for a v7 primary key, and
  # whether the database can resolve each one. A list of failed checks, empty
  # when there is nothing wrong.
  @spec check_uuid_generate_v7(module(), [module()]) :: [check()]
  def check_uuid_generate_v7(repo, resources) do
    resources = Enum.filter(resources, &needs_uuid_v7_function?/1)

    if resources == [] do
      []
    else
      wanted =
        [repo_uuid_v7_function(repo) | Enum.flat_map(resources, &table_defaults(repo, &1))]
        |> Enum.uniq()

      Enum.flat_map(wanted, fn function ->
        case resolvable(repo, function) do
          :ok -> []
          {:missing, detail} -> [%{check: :uuid_generate_v7, function: function, detail: detail}]
        end
      end)
    end
  end

  # ash_postgres's own condition for writing `fragment("uuid_generate_v7()")`
  # rather than nothing: the attribute's default is `&Ash.UUIDv7.generate/0`.
  # Matching on the same capture means this cannot drift from what the
  # migration will actually say.
  defp needs_uuid_v7_function?(nil), do: false

  defp needs_uuid_v7_function?(resource) do
    Code.ensure_loaded?(resource) and
      Enum.any?(Ash.Resource.Info.attributes(resource), fn attribute ->
        attribute.primary_key? and attribute.default == (&Ash.UUIDv7.generate/0)
      end)
  rescue
    _ -> false
  end

  # Which function ash_postgres will name in the NEXT migration it writes for
  # this repo. `use_builtin_uuidv7_function?/0` is `min_pg_version/0`'s major
  # at 18 or more.
  defp repo_uuid_v7_function(repo) do
    if function_exported?(repo, :use_builtin_uuidv7_function?, 0) and
         repo.use_builtin_uuidv7_function?() do
      "uuidv7()"
    else
      "uuid_generate_v7()"
    end
  end

  # Which function the table's primary key column ALREADY defaults to, for
  # every schema that has such a table — a per-tenant host has one per tenant.
  # This is what the database will actually run at the next INSERT, whatever
  # the repo now answers.
  defp table_defaults(repo, resource) do
    with table when is_binary(table) <- resource_table(resource),
         {:ok, %{rows: rows}} <- query(repo, column_default_sql(), [table]) do
      rows
      |> Enum.map(fn [_schema, default] -> default end)
      |> Enum.filter(&is_binary/1)
      |> Enum.flat_map(fn default ->
        case Regex.run(~r/\b(uuid_generate_v7|uuidv7)\(\)/, default) do
          [_, name] -> ["#{name}()"]
          nil -> []
        end
      end)
    else
      _ -> []
    end
  end

  defp resource_table(resource) do
    AshPostgres.DataLayer.Info.table(resource)
  rescue
    _ -> nil
  end

  # `pg_attrdef` rather than `information_schema.columns`: the latter hides
  # defaults on tables the current role cannot see in full, and this runs in a
  # host's boot.
  defp column_default_sql do
    """
    SELECT n.nspname, pg_get_expr(d.adbin, d.adrelid)
    FROM pg_attrdef d
    JOIN pg_class c ON c.oid = d.adrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = d.adnum
    WHERE c.relname::text = $1::text AND a.attname = 'id'
    """
  end

  # Can the database resolve this function? Three answers, because the middle
  # one is the per-tenant trap: the function exists, in one schema, and the
  # connection that would run `CREATE TABLE` cannot see it.
  defp resolvable(repo, function) do
    case query(repo, "SELECT to_regprocedure($1::text) IS NOT NULL", [function]) do
      {:ok, %{rows: [[true]]}} ->
        :ok

      {:ok, %{rows: [[_]]}} ->
        {:missing, unresolvable_detail(repo, function)}

      {:error, exception} ->
        {:missing,
         "the check itself could not run: #{Exception.message(exception)}\n" <>
           "Is #{inspect(repo)} started?"}

      _other ->
        {:missing, unresolvable_detail(repo, function)}
    end
  end

  defp unresolvable_detail(repo, function) do
    name = function |> String.trim_trailing("()")

    case query(repo, schemas_sql(), [name]) do
      {:ok, %{rows: [_ | _] = rows}} ->
        schemas = rows |> Enum.map(fn [schema] -> schema end) |> Enum.join(", ")

        """
        #{function} EXISTS, in #{schemas}, but this connection cannot resolve
        it: its search_path is #{search_path(repo)}.

        That is the per-tenant trap. The function is created once, in one
        schema, and a CREATE TABLE in a tenant's schema resolves it against
        the search_path of whoever runs it. Leave `public` (or whichever
        schema holds it) on that connection's path, or schema-qualify the
        column default.
        """

      _ ->
        """
        #{function} does not exist in this database. #{why_missing(function)}
        """
    end
  end

  defp why_missing("uuidv7()") do
    """
    It is PostgreSQL's own, and only from version 18. `min_pg_version/0` on
    your repo answers 18 or more, so ash_postgres writes `uuidv7()` as the
    column default and creates nothing — set it to the OLDEST server you run
    and generate the migration again.
    """
  end

  defp why_missing(_function) do
    """
    ash_postgres creates it, in its `ash-functions` migration, and only when
    it is not relying on the server's own: it leaves it out when
    `min_pg_version/0` answers 18 or more. A migration generated while that
    answered 18 creates nothing, and lowering the answer afterwards does not
    rewrite a file already on disk — which is how a repo that lists
    "ash-functions" ends up without the function (#50).
    """
  end

  defp schemas_sql do
    """
    SELECT n.nspname
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE p.proname::text = $1::text
    """
  end

  defp search_path(repo) do
    case query(repo, "SELECT current_setting('search_path')", []) do
      {:ok, %{rows: [[path]]}} -> path
      _ -> "unknown"
    end
  end

  # A repo that is not started raises from the pool, and DBConnection can exit
  # rather than raise. Either way this must come back as a check that failed,
  # not as a crash in the host's boot.
  defp query(repo, sql, params) do
    repo.query(sql, params)
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, %RuntimeError{message: "the query exited: #{inspect(reason)}"}}
  end

  # ============================================================================
  # Reporting
  # ============================================================================

  defp default_resources do
    [
      Config.notification_resource(),
      Config.preference_resource(),
      Config.delivery_receipt_resource()
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp error(checks) do
    %Error{checks: checks, message: message(checks)}
  end

  defp message(checks) do
    details = Enum.map_join(checks, "\n", &"  - #{String.trim(&1.detail)}")

    """
    AshDispatch.Doctor found #{length(checks)} problem(s) with this database:

    #{details}

    #{migration_to_add()}
    """
  end

  # ash_postgres's own definition, copied from
  # `AshPostgres.MigrationGenerator.AshFunctions`. Keep taking it from
  # ash_postgres rather than from here if the two ever differ.
  @uuid_generate_v7_sql ~S"""
  CREATE OR REPLACE FUNCTION uuid_generate_v7()
  RETURNS UUID
  AS $$
  DECLARE
    timestamp    TIMESTAMPTZ;
    microseconds INT;
  BEGIN
    timestamp    = clock_timestamp();
    microseconds = (cast(extract(microseconds FROM timestamp)::INT - (floor(extract(milliseconds FROM timestamp))::INT * 1000) AS DOUBLE PRECISION) * 4.096)::INT;

    RETURN encode(
      set_byte(
        set_byte(
          overlay(uuid_send(gen_random_uuid()) placing substring(int8send(floor(extract(epoch FROM timestamp) * 1000)::BIGINT) FROM 3) FROM 1 FOR 6
        ),
        6, (b'0111' || (microseconds >> 8)::bit(4))::bit(8)::int
      ),
      7, microseconds::bit(8)::int
    ),
    'hex')::UUID;
  END
  $$
  LANGUAGE PLPGSQL
  SET search_path = ''
  VOLATILE;
  """

  @doc """
  The migration that adds `uuid_generate_v7()`, as a string.

  The ordinary route is `mix ash.codegen install_ash_functions`, which writes
  this and the other functions Ash expects. This is here for a host that
  cannot run it — a schema someone else owns, migrations written by hand —
  and is ash_postgres's own definition, copied. Keep taking it from
  ash_postgres rather than from here if the two ever differ.
  """
  @spec migration_to_add() :: String.t()
  def migration_to_add do
    """
    The migration to add:

        mix ash.codegen install_ash_functions
        mix ash.migrate

    ash_postgres notices the extension and writes the migration for it,
    together with the other functions Ash expects. If `min_pg_version/0`
    answers 18 or more it writes nothing, so set that to the oldest server you
    run first.

    If you cannot run `ash.codegen` — a schema someone else owns, migrations
    written by hand — the function is one statement. Execute this from the
    `up/0` of a migration of your own:

    #{indent(@uuid_generate_v7_sql)}
    and `DROP FUNCTION IF EXISTS uuid_generate_v7()` from its `down/0`.

    Or ask the bases for a v4 key, which needs no function at all:

        use AshDispatch.Resources.Notification.Base,
          repo: MyApp.Repo,
          domain: MyApp.Notifications,
          primary_key: :uuid

    See the Tenancy guide's "uuid_generate_v7()" section for the whole of it.
    """
  end

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> "    " <> line
    end)
  end
end
