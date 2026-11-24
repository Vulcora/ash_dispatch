defmodule Mix.Tasks.AshDispatch.Install.Docs do
  @moduledoc false

  def short_doc do
    "Installs AshDispatch into a project"
  end

  def example do
    "mix igniter.install ash_dispatch"
  end

  def long_doc do
    """
    #{short_doc()}

    This installer will:
    - Add AshDispatch configuration to config files
    - Create Notification, DeliveryReceipt and Preference resources
    - Create Notifications and Deliveries domains
    - Add domains to your :ash_domains configuration
    - Give Oban the queues and the two scheduled workers AshDispatch needs
    - Create a RecipientResolver module for declarative audience resolution
    - Set up email layout templates
    - Optionally set up Phoenix channel for real-time updates

    It is safe to run twice: nothing it has already written is written again,
    and a value you have set yourself is never changed.

    ## Example

    ```bash
    #{example()}
    ```

    ## Options

    * `--no-phoenix` - Skip Phoenix channel setup
    * `--no-email` - Skip email backend configuration
    * `--no-typescript` - Generate plain resources and skip TypeScript SDK generation. Without
      the flag, the resources get `AshTypescript.Resource` when ash_typescript is a dependency, and
      the SDK is generated when a domain uses `AshTypescript.Rpc`.
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshDispatch.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()}"

    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :ash,
        installs: [{:ash, "~> 3.0"}, {:oban, "~> 2.12"}],
        example: __MODULE__.Docs.example(),
        schema: [
          phoenix: :boolean,
          email: :boolean,
          typescript: :boolean
        ],
        defaults: [
          phoenix: true,
          email: true,
          typescript: true
        ],
        aliases: []
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      opts = igniter.args.options
      otp_app = Igniter.Project.Application.app_name(igniter)

      # `module_name_prefix/1`, not `module_name(igniter, "")`: concatenating
      # an empty segment yields `MyApp.` with a trailing dot, which made every
      # module this installer generated `MyApp..Notifications…`.
      app_module = Igniter.Project.Module.module_name_prefix(igniter)

      # Both resources are AshPostgres resources and need a repo. With none in
      # the project the conventional name is used, and the notice says so.
      {igniter, found_repo} =
        Igniter.Libs.Ecto.select_repo(igniter, label: "Which repo should AshDispatch use?")

      repo = found_repo || Module.concat(app_module, Repo)

      user_resource = detect_user_resource(igniter, app_module)

      # `--no-typescript` used to skip only the SDK, while the library itself
      # still required ash_typescript (#31). It now also keeps the generated
      # resources plain — as does a project that doesn't have ash_typescript.
      typescript? =
        opts[:typescript] && Igniter.Project.Deps.has_dep?(igniter, :ash_typescript)

      igniter
      |> Igniter.Project.Formatter.import_dep(:ash_dispatch)
      |> configure_ash_dispatch(otp_app, app_module, repo)
      |> configure_test(otp_app)
      |> configure_oban(otp_app)
      |> create_notification_resource(app_module, repo, user_resource, typescript?)
      |> create_delivery_receipt_resource(app_module, repo, user_resource, typescript?)
      |> create_preference_resource(app_module, repo, typescript?)
      |> create_notifications_domain(app_module)
      |> create_deliveries_domain(app_module)
      |> add_domains_to_config(otp_app, app_module)
      |> create_recipient_resolver(app_module, user_resource)
      |> setup_email_layouts()
      |> maybe_setup_phoenix(opts[:phoenix], otp_app, app_module)
      |> maybe_configure_email(opts[:email], otp_app, app_module)
      |> maybe_run_typescript(opts[:typescript])
      |> maybe_warn_missing_ash_functions(otp_app, repo, app_module)
      |> add_final_notice(app_module, found_repo, user_resource)
    end

    # ============================================
    # uuid_generate_v7()
    # ============================================

    # The notification and preference resources written above have a
    # `uuid_v7_primary_key`, so `mix ash.codegen` writes
    # `default: fragment("uuid_generate_v7()")` into their migration. Postgres
    # has no such function before 18: ash_postgres creates it, in its
    # `ash-functions` migration, and only for a repo whose
    # `installed_extensions/0` lists `"ash-functions"`. Where it is missing,
    # `CREATE TABLE` fails — and for a host that creates a tenant's tables when
    # the tenant is created, no tenant can be created at all (#50).
    #
    # rc.2 asked one question — does the repo's source contain
    # `"ash-functions"` — and the first host it was written for answered yes
    # while the function was absent. ash_postgres emits the function only when
    # the builtin is NOT used, and it derives that from `min_pg_version/0`
    # (`major >= 18`). The host's `ash-functions` migration had been generated
    # while that answered 18, so it created nothing; lowering the answer to 17
    # afterwards does not rewrite a migration already on disk.
    #
    # So three things are read instead of one, all from the project's own
    # files, still without a database connection:
    #
    #   * does `installed_extensions/0` list `"ash-functions"`
    #   * what does `min_pg_version/0` answer
    #   * does a migration that installs Ash's functions already exist, and
    #     does it define `uuid_generate_v7()`
    #
    # None of that is conclusive — only the database can be — so every notice
    # now says so and gives the SQL check as the authoritative one.
    @migration_glob "priv/**/migrations/*.exs"

    defp maybe_warn_missing_ash_functions(igniter, otp_app, repo, app_module) do
      case Igniter.Project.Module.find_module(igniter, repo) do
        {:ok, {igniter, source, _zipper}} ->
          repo_source = Rewrite.Source.get(source, :content)
          {igniter, migrations} = ash_functions_migrations(igniter)

          case diagnose_uuid_generate_v7(repo_source, migrations) do
            :ok ->
              igniter

            {:warn, reason} ->
              Igniter.add_notice(
                igniter,
                ash_functions_notice(reason, otp_app, repo, app_module)
              )
          end

        # No repo of that name to read. The closing notice already says so;
        # warning about a file that is not there would only be noise.
        {:error, igniter} ->
          igniter
      end
    end

    @doc false
    # What the project's files say about `uuid_generate_v7()`. Public only so
    # the suite can put the three inputs in directly; not API.
    #
    # `:ok` means "nothing here looks wrong", NOT "the function is there" —
    # the installer cannot know that. Each `{:warn, reason}` names a case in
    # which it is positively likely to be missing.
    def diagnose_uuid_generate_v7(repo_source, migrations) do
      cond do
        not String.contains?(repo_source, ~s("ash-functions")) ->
          {:warn, :no_extension}

        # Checked before the migration, because this answer decides the next
        # `mix ash.codegen` too: at 18 ash_postgres writes `uuidv7()` as the
        # column default of every new table, which an older server does not
        # have either. Worth saying whatever the migrations currently contain.
        min_pg_major(repo_source) >= 18 ->
          {:warn, :builtin_assumed}

        # The migration is already written and does not create the function.
        # The strongest signal there is, and the host's own case: the answer
        # was lowered to 17 after the file had been generated.
        migrations == :installed_without_function ->
          {:warn, :migration_without_function}

        true ->
          :ok
      end
    end

    # The major version `min_pg_version/0` answers, or 0 when the repo does not
    # define one (ash_postgres then assumes 13 and warns about it itself).
    # Both spellings ash_postgres and its installer write are read:
    # `%Version{major: 18, …}` and `Version.parse!("18.0.0")`.
    defp min_pg_major(repo_source) do
      case Regex.run(~r/min_pg_version.*?(?:major:\s*|parse!\(")(\d+)/s, repo_source) do
        [_, major] -> String.to_integer(major)
        _ -> 0
      end
    end

    # Whether a migration that installs Ash's functions exists, and whether it
    # defines `uuid_generate_v7()`. `FUNCTION uuid_generate_v7` is the
    # DEFINITION; a bare `uuid_generate_v7()` also appears in every table
    # migration as a column default, which is the use and proves nothing.
    defp ash_functions_migrations(igniter) do
      igniter = Igniter.include_glob(igniter, @migration_glob)

      contents =
        igniter.rewrite
        |> Rewrite.sources()
        |> Enum.filter(&migration_path?(Rewrite.Source.get(&1, :path)))
        |> Enum.map(&Rewrite.Source.get(&1, :content))

      cond do
        Enum.any?(contents, &String.contains?(&1, "FUNCTION uuid_generate_v7")) ->
          {igniter, :installed_with_function}

        Enum.any?(contents, &installs_ash_functions?/1) ->
          {igniter, :installed_without_function}

        true ->
          {igniter, :none}
      end
    end

    defp migration_path?(path) when is_binary(path) do
      String.contains?(path, "migrations/") and String.ends_with?(path, ".exs")
    end

    defp migration_path?(_path), do: false

    # ash_postgres's `ash-functions` migration always creates these, whatever
    # version of it generated the file and whichever Postgres it assumed.
    defp installs_ash_functions?(content) do
      Enum.any?(
        ["FUNCTION ash_raise_error", "FUNCTION ash_elixir_or", "FUNCTION ash_required"],
        &String.contains?(content, &1)
      )
    end

    # The authoritative check, in every notice: the database, not the source.
    defp ash_functions_sql_check do
      """
      Listing the extension is NOT enough to know the function is there. Ask
      the database — this is the only answer that counts:

          SELECT to_regprocedure('public.uuid_generate_v7()');

      NULL means it is not there. From inside the application, at boot or in a
      test:

          AshDispatch.Doctor.check!()        # raises with the migration to add
          mix ash_dispatch.doctor            # the same check from the shell
      """
    end

    defp ash_functions_fix(otp_app, repo, app_module) do
      """
      To add it:

          defmodule #{inspect(repo)} do
            use AshPostgres.Repo, otp_app: :#{otp_app}

            def installed_extensions, do: ["ash-functions"]

            # The OLDEST Postgres you run. At 18 or more ash_postgres uses the
            # server's own uuidv7() and creates nothing.
            def min_pg_version, do: %Version{major: 17, minor: 0, patch: 0}
          end

          mix ash.codegen install_ash_functions
          mix ash.migrate

      Or keep v4 keys, which need no function at all:

          use AshDispatch.Resources.Notification.Base,
            repo: #{inspect(repo)},
            domain: #{inspect(Module.concat(app_module, Notifications))},
            primary_key: :uuid

      If you create each tenant's tables when the tenant is created, read the
      "uuid_generate_v7()" section of the Tenancy guide before your first one:
      the function lives in one schema and is resolved against the search_path
      of whoever runs the CREATE TABLE.
      """
    end

    defp ash_functions_notice(:no_extension, otp_app, repo, app_module) do
      """
      ⚠️  #{inspect(repo)} does not list the "ash-functions" extension, and the
      notification and preference resources have a UUID v7 primary key.

      `mix ash.codegen` writes `default: fragment("uuid_generate_v7()")` for
      their tables. Postgres has no such function before 18 — ash_postgres
      creates it, and only for a repo that asks. Without it CREATE TABLE fails.

      #{ash_functions_sql_check()}
      #{ash_functions_fix(otp_app, repo, app_module)}
      """
    end

    defp ash_functions_notice(:migration_without_function, otp_app, repo, app_module) do
      """
      ⚠️  #{inspect(repo)} lists "ash-functions", but the migration that
      installs them does not create uuid_generate_v7() — and the notification
      and preference resources have a UUID v7 primary key.

      ash_postgres creates that function only when the server's own is not
      used, which it decides from `min_pg_version/0`: at major 18 or more it
      leaves it out and relies on the builtin uuidv7(). A migration generated
      while that answered 18 therefore creates nothing, and lowering the answer
      afterwards does not rewrite a file already on disk.

      This is exactly the case that reached the first per-tenant host (#50):
      the extension was listed, and the function was missing.

      #{ash_functions_sql_check()}
      If it is missing, set `min_pg_version/0` to the oldest server you
      actually run and generate the migration again:

          mix ash.codegen install_ash_functions
          mix ash.migrate

      `AshDispatch.Doctor` prints the statement to run by hand when
      `ash.codegen` is not available to you.
      #{ash_functions_fix(otp_app, repo, app_module)}
      """
    end

    defp ash_functions_notice(:builtin_assumed, otp_app, repo, app_module) do
      """
      ⚠️  #{inspect(repo)} lists "ash-functions", but `min_pg_version/0`
      answers 18 or more — so ash_postgres will NOT create
      uuid_generate_v7(). It will rely on the server's own uuidv7() instead,
      which exists only on PostgreSQL 18 and later.

      The notification and preference resources have a UUID v7 primary key. If
      any server you run is older than 18, CREATE TABLE fails there.

      `min_pg_version/0` should be the OLDEST Postgres the application runs
      against, not the newest or the one on your laptop —
      `mix igniter.install ash_postgres` fills it in from the local
      `postgres -V`, which is how 18 gets written into a project that deploys
      against 17.

      #{ash_functions_sql_check()}
      #{ash_functions_fix(otp_app, repo, app_module)}
      """
    end

    # ============================================
    # Configuration
    # ============================================

    # The resource keys are how the runtime finds the resources generated
    # below (`Config.notification_resource/0` and friends return `nil`
    # otherwise), and `:repo` is read directly for Oban job lookups.
    #
    # `configure_new/5` throughout: a value the host has already set is never
    # changed, which is also what makes a second run of the installer a no-op.
    defp configure_ash_dispatch(igniter, otp_app, app_module, repo) do
      [
        otp_app: otp_app,
        repo: repo,
        notification_resource: Module.concat([app_module, Notifications, Notification]),
        delivery_receipt_resource: Module.concat([app_module, Deliveries, DeliveryReceipt]),
        preference_resource: Module.concat([app_module, Notifications, Preference]),
        user_preference: AshDispatch.UserPreference.Resource
      ]
      |> Enum.reduce(igniter, fn {key, value}, igniter ->
        Igniter.Project.Config.configure_new(igniter, "config.exs", :ash_dispatch, [key], value)
      end)
    end

    # ============================================
    # Oban: the queues and the two scheduled workers
    # ============================================

    # Every queue the library's workers name, and the cron entries without
    # which a failed delivery is never tried again and a sensitive body is
    # never emptied. The installer printed this and left it to the reader for
    # four releases (BACKLOG 1); a host that missed it lost mail silently.
    @queues [default: 10, emails: 10, sms: 5, webhooks: 5]

    @crontab [
      ~s({"*/5 * * * *", AshDispatch.Workers.RetryFailedDeliveries}),
      ~s({"0 * * * *", AshDispatch.Workers.ScrubSensitiveContent})
    ]

    defp configure_oban(igniter, otp_app) do
      igniter
      |> Igniter.Project.Config.configure(
        "config.exs",
        otp_app,
        [Oban, :queues],
        @queues,
        updater: &add_missing_queues/1
      )
      |> Igniter.Project.Config.configure(
        "config.exs",
        otp_app,
        [Oban, :plugins],
        {:code, Sourceror.parse_string!("[" <> cron_plugin() <> "]")},
        updater: &add_missing_cron/1
      )
    end

    defp cron_plugin do
      """
      {Oban.Plugins.Cron,
       crontab: [
         #{Enum.join(@crontab, ",\n     ")}
       ]}
      """
    end

    # A queue the host already lists keeps the size the host gave it: a
    # concurrency someone chose is a decision, not a gap to fill.
    defp add_missing_queues(zipper) do
      Enum.reduce_while(@queues, {:ok, zipper}, fn {name, size}, {:ok, zipper} ->
        case Igniter.Code.Keyword.set_keyword_key(zipper, name, size, &{:ok, &1}) do
          {:ok, zipper} -> {:cont, {:ok, zipper}}
          _other -> {:halt, :error}
        end
      end)
    end

    # The host already has plugins. Find their Cron entry and add only the
    # workers it is missing — a schedule the host chose for one of ours is
    # left exactly as it is, which is why the comparison is on the worker and
    # not on the whole entry. No Cron plugin at all: append ours beside
    # theirs. Anything shaped in a way we do not recognise is left alone
    # (`:error` means "change nothing"), and the closing notice still says
    # what is needed.
    defp add_missing_cron(zipper) do
      case Igniter.Code.List.move_to_list_item(zipper, &cron_plugin?/1) do
        {:ok, cron} ->
          add_crontab_entries(cron)

        :error ->
          Igniter.Code.List.append_new_to_list(
            zipper,
            Sourceror.parse_string!(cron_plugin())
          )
      end
    end

    defp cron_plugin?(zipper) do
      Igniter.Code.Tuple.tuple?(zipper) and
        Igniter.Code.Tuple.elem_equals?(zipper, 0, Oban.Plugins.Cron)
    end

    defp add_crontab_entries(cron) do
      with {:ok, opts} <- Igniter.Code.Tuple.tuple_elem(cron, 1),
           {:ok, crontab} <- Igniter.Code.Keyword.get_key(opts, :crontab) do
        Enum.reduce_while(@crontab, {:ok, crontab}, fn entry, {:ok, zipper} ->
          entry = Sourceror.parse_string!(entry)

          case Igniter.Code.List.append_new_to_list(zipper, entry, &same_worker?/2) do
            {:ok, zipper} -> {:cont, {:ok, zipper}}
            _other -> {:halt, :error}
          end
        end)
      else
        _ -> :error
      end
    end

    # Two crontab entries are "the same" when they name the same worker,
    # whatever schedule or options they carry. Both sides go through
    # `tuple_elem/2` rather than being destructured: Sourceror parses a
    # two-element tuple as `{:{}, meta, [_, _]}` so it can hold metadata, and
    # a pattern on `{schedule, worker}` therefore never matched — which made
    # every run append the entries again.
    defp same_worker?(existing, new) do
      with {:ok, mine} <- Igniter.Code.Tuple.tuple_elem(Sourceror.Zipper.zip(new), 1),
           {:ok, theirs} <- Igniter.Code.Tuple.tuple_elem(existing, 1) do
        Igniter.Code.Common.nodes_equal?(theirs, Sourceror.Zipper.node(mine))
      else
        _ -> false
      end
    end

    defp configure_test(igniter, otp_app) do
      # Configure Oban for inline testing if Oban config exists
      igniter
      |> Igniter.Project.Config.configure_new(
        "test.exs",
        otp_app,
        [Oban, :testing],
        :inline
      )
    end

    # ============================================
    # Resource Generation
    # ============================================

    # `create_module/3` wraps the contents in `defmodule` itself, so every
    # generator below passes only the module body. Passing a whole
    # `defmodule` — as this installer used to — nests a second module inside
    # the first and leaves the outer one empty.
    #
    # The resources are built on the same Base modules the integration guide
    # uses. They used to `use AshDispatch.Notification` and
    # `use AshDispatch.DeliveryReceipt`, which have never existed.
    defp create_notification_resource(igniter, app_module, repo, user_resource, typescript?) do
      module_name = Module.concat([app_module, Notifications, Notification])

      # Base already defines `user_id`, so the relationship must not define
      # it again.
      relationships =
        if user_resource do
          """
          relationships do
            belongs_to :user, #{inspect(user_resource)} do
              source_attribute :user_id
              destination_attribute :id
              allow_nil? false
              public? true
              define_attribute? false
            end
          end
          """
        else
          """
          # No user resource was found. Add a relationship to yours:
          #
          #   relationships do
          #     belongs_to :user, #{inspect(app_module)}.Accounts.User do
          #       source_attribute :user_id
          #       destination_attribute :id
          #       allow_nil? false
          #       public? true
          #       define_attribute? false
          #     end
          #   end
          """
        end

      content = """
      @moduledoc \"\"\"
      In-app notifications for users.

      Generated by `mix ash_dispatch.install`.
      \"\"\"

      use AshDispatch.Resources.Notification.Base,
        repo: #{inspect(repo)},
        domain: #{inspect(Module.concat(app_module, Notifications))}#{typescript_extension(typescript?)}

      #{typescript_section(typescript?, "Notification")}
      #{relationships}
      """

      create_module(igniter, module_name, content)
    end

    # `create_module/3` fails the run when the file is already there
    # (`on_exists: :error`, and it takes no options), so the installer could
    # not be run twice: the second run reported "File already exists" and
    # stopped. A module that exists is the host's now — skip it.
    defp create_module(igniter, module_name, content) do
      case Igniter.Project.Module.module_exists(igniter, module_name) do
        {true, igniter} -> igniter
        {false, igniter} -> Igniter.Project.Module.create_module(igniter, module_name, content)
      end
    end

    defp create_delivery_receipt_resource(igniter, app_module, repo, user_resource, typescript?) do
      module_name = Module.concat([app_module, Deliveries, DeliveryReceipt])

      # Base builds the user relationship itself when given `user_resource`.
      user_resource_opt =
        if user_resource, do: ",\n  user_resource: #{inspect(user_resource)}", else: ""

      content = """
      @moduledoc \"\"\"
      Tracks every notification delivery (email, in-app, webhooks, ...).

      Generated by `mix ash_dispatch.install`.
      \"\"\"

      use AshDispatch.Resources.DeliveryReceipt.Base,
        repo: #{inspect(repo)},
        domain: #{inspect(Module.concat(app_module, Deliveries))},
        notification_resource: #{inspect(Module.concat([app_module, Notifications, Notification]))}#{user_resource_opt}#{typescript_extension(typescript?)}

      #{typescript_section(typescript?, "DeliveryReceipt")}
      """

      create_module(igniter, module_name, content)
    end

    # Rows per (tenant, person or the tenant's default, event or category,
    # transport). Generated because `user_preference:` above points at
    # `AshDispatch.UserPreference.Resource`, which reads this resource: a new
    # install gets working preferences instead of a checker configured to read
    # a table nobody created.
    defp create_preference_resource(igniter, app_module, repo, typescript?) do
      module_name = Module.concat([app_module, Notifications, Preference])

      content = """
      @moduledoc \"\"\"
      Per-person notification preferences: who wants which event, on which
      transport. The person beats the tenant's default, the tenant beats the
      event's own.

      Generated by `mix ash_dispatch.install`.
      \"\"\"

      use AshDispatch.Resources.Preference.Base,
        repo: #{inspect(repo)},
        domain: #{inspect(Module.concat(app_module, Notifications))}#{typescript_extension(typescript?)}

      #{typescript_section(typescript?, "NotificationPreference")}
      """

      create_module(igniter, module_name, content)
    end

    defp typescript_extension(true), do: ",\n  extensions: [AshTypescript.Resource]"
    defp typescript_extension(_typescript?), do: ""

    # `type_name` is required once the extension is present.
    defp typescript_section(true, type_name) do
      """
      typescript do
        type_name "#{type_name}"
      end
      """
    end

    defp typescript_section(_typescript?, _type_name), do: ""

    # ============================================
    # Domain Generation
    # ============================================

    defp create_notifications_domain(igniter, app_module) do
      module_name = Module.concat(app_module, Notifications)
      notification = Module.concat([app_module, Notifications, Notification])
      preference = Module.concat([app_module, Notifications, Preference])

      content = """
      @moduledoc \"\"\"
      Domain for in-app notifications and notification preferences.

      Generated by `mix ash_dispatch.install`.
      \"\"\"

      use Ash.Domain

      resources do
        resource #{inspect(notification)}
        resource #{inspect(preference)}
      end
      """

      create_module(igniter, module_name, content)
    end

    defp create_deliveries_domain(igniter, app_module) do
      module_name = Module.concat(app_module, Deliveries)
      resource_name = Module.concat([app_module, Deliveries, DeliveryReceipt])

      content = """
      @moduledoc \"\"\"
      Domain for delivery receipts and tracking.

      Generated by `mix ash_dispatch.install`.
      \"\"\"

      use Ash.Domain

      resources do
        resource #{inspect(resource_name)}
      end
      """

      create_module(igniter, module_name, content)
    end

    defp add_domains_to_config(igniter, otp_app, app_module) do
      notifications_domain = Module.concat(app_module, Notifications)
      deliveries_domain = Module.concat(app_module, Deliveries)

      igniter
      |> Igniter.Project.Config.configure(
        "config.exs",
        otp_app,
        [:ash_domains],
        [notifications_domain, deliveries_domain],
        updater: fn zipper ->
          zipper
          |> Igniter.Code.List.append_new_to_list(notifications_domain)
          |> case do
            {:ok, zipper} -> Igniter.Code.List.append_new_to_list(zipper, deliveries_domain)
            other -> other
          end
        end
      )
    end

    # ============================================
    # Recipient Resolver
    # ============================================

    # `use AshDispatch.RecipientResolver` requires a user resource, and
    # `to_recipient/1` matches on its struct, which only compiles if the
    # module exists. Without one there is nothing valid to generate yet; the
    # final notice explains how to add it later.
    defp create_recipient_resolver(igniter, _app_module, nil), do: igniter

    defp create_recipient_resolver(igniter, app_module, user_resource) do
      resolver_module = Module.concat(app_module, RecipientResolver)
      user_resource_str = inspect(user_resource)

      content = """
      @moduledoc \"\"\"
      Recipient resolver for notification audiences.

      Define how to resolve recipients for each audience type using
      the AshDispatch.RecipientResolver DSL.

      ## Audience Strategies

      | Strategy | Example | Description |
      |----------|---------|-------------|
      | `from_context` | `from_context: :user` | Extract from context.data |
      | `query` | `query: [role: :admin]` | Query user_resource with Ash filter |
      | `path` | `path: [:team, :users]` | Follow relationship path on resource |
      | `combine` | `combine: [:owner, :team]` | Union of other audiences |
      | `resolve` | `resolve: :resolve_owner` | Custom resolver function |

      ## Usage

      Reference audiences in your dispatch DSL:

          dispatch do
            event :order_created do
              channel :in_app, audience: :owner
              channel :email, audience: :team
            end
          end
      \"\"\"

      use AshDispatch.RecipientResolver,
        user_resource: #{user_resource_str}

      audiences do
        # Context-based - extract user from event context
        audience :user, from_context: :user

        # Fallback chain - tries :user first, then :assignee
        audience :assignee, from_context: [:user, :assignee]

        # Query-based - find users matching filter
        # audience :admins, query: [role: :admin, is_active: true]

        # Relationship path - follow relationships on the resource
        # audience :team, path: [:team_members, :user]

        # Composite - union of other audiences (deduped by id)
        # audience :stakeholders, combine: [:owner, :team]

        # Custom resolver - for complex business logic
        # audience :owner, resolve: :resolve_owner

        # Custom resolver returning raw maps (not user structs)
        # audience :lead_contact, resolve: :resolve_lead_contact, raw: true
      end

      @impl true
      def to_recipient(%#{user_resource_str}{} = user) do
        %{
          id: user.id,
          email: to_string(user.email),
          display_name: extract_display_name(user)
        }
      end

      defp extract_display_name(user) do
        cond do
          Map.has_key?(user, :full_name) && user.full_name ->
            to_string(user.full_name)

          Map.has_key?(user, :first_name) && user.first_name ->
            to_string(user.first_name)

          true ->
            to_string(user.email)
        end
      end

      # Example custom resolver:
      #
      # def resolve_owner(resource, context) do
      #   case Map.get(context.data, :owner) do
      #     nil -> []
      #     owner -> [owner]
      #   end
      # end
      """

      igniter
      |> create_module(resolver_module, content)
      |> Igniter.Project.Config.configure_new(
        "config.exs",
        :ash_dispatch,
        [:recipient_resolver],
        resolver_module
      )
    end

    # ============================================
    # Email Layouts
    # ============================================

    defp setup_email_layouts(igniter) do
      html_layout = email_html_layout_content()
      text_layout = email_text_layout_content()

      igniter
      |> Igniter.create_new_file(
        "priv/ash_dispatch/layouts/email.html.heex",
        html_layout,
        on_exists: :skip
      )
      |> Igniter.create_new_file(
        "priv/ash_dispatch/layouts/email.text.eex",
        text_layout,
        on_exists: :skip
      )
    end

    defp email_html_layout_content do
      ~S"""
      <!DOCTYPE html>
      <html lang="en">
      <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <meta http-equiv="X-UA-Compatible" content="IE=edge">
        <title><%= @subject %></title>
        <!--[if mso]>
        <noscript>
          <xml>
            <o:OfficeDocumentSettings>
              <o:PixelsPerInch>96</o:PixelsPerInch>
            </o:OfficeDocumentSettings>
          </xml>
        </noscript>
        <![endif]-->
        <style type="text/css">
          /* Reset styles */
          body, table, td, p, a, li, blockquote {
            -webkit-text-size-adjust: 100%;
            -ms-text-size-adjust: 100%;
          }
          table, td {
            mso-table-lspace: 0pt;
            mso-table-rspace: 0pt;
          }
          img {
            -ms-interpolation-mode: bicubic;
            border: 0;
            height: auto;
            line-height: 100%;
            outline: none;
            text-decoration: none;
          }
          body {
            margin: 0 !important;
            padding: 0 !important;
            width: 100% !important;
            background-color: #f4f4f5;
          }
          /* Link styles */
          a {
            color: #2563eb;
            text-decoration: none;
          }
          a:hover {
            text-decoration: underline;
          }
        </style>
      </head>
      <body style="margin: 0; padding: 0; background-color: #f4f4f5; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;">
        <!-- Wrapper table -->
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color: #f4f4f5;">
          <tr>
            <td align="center" style="padding: 40px 20px;">
              <!-- Main content container -->
              <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width: 600px; background-color: #ffffff; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.1);">
                <!-- Header -->
                <tr>
                  <td style="padding: 32px 40px 24px 40px; border-bottom: 1px solid #e5e7eb;">
                    <!-- Replace with your logo -->
                    <img src="https://via.placeholder.com/150x40?text=Your+Logo" alt="Logo" style="max-height: 40px; width: auto;">
                  </td>
                </tr>

                <!-- Body content -->
                <tr>
                  <td style="padding: 32px 40px;">
                    <%= @inner_content %>
                  </td>
                </tr>

                <!-- Footer -->
                <tr>
                  <td style="padding: 24px 40px 32px 40px; border-top: 1px solid #e5e7eb; background-color: #f9fafb; border-radius: 0 0 8px 8px;">
                    <p style="margin: 0 0 8px 0; font-size: 12px; color: #6b7280; text-align: center;">
                      This email was sent by Your Company Name
                    </p>
                    <p style="margin: 0; font-size: 12px; color: #6b7280; text-align: center;">
                      <a href="#" style="color: #6b7280; text-decoration: underline;">Unsubscribe</a> &middot;
                      <a href="#" style="color: #6b7280; text-decoration: underline;">Privacy Policy</a>
                    </p>
                  </td>
                </tr>
              </table>
            </td>
          </tr>
        </table>
      </body>
      </html>
      """
    end

    defp email_text_layout_content do
      """
      <%= @inner_content %>

      ---
      This email was sent by Your Company Name
      To unsubscribe, visit: [unsubscribe link]
      """
    end

    # ============================================
    # Phoenix Integration
    # ============================================

    defp maybe_setup_phoenix(igniter, false, _otp_app, _app_module), do: igniter

    defp maybe_setup_phoenix(igniter, true, otp_app, app_module) do
      web_module = detect_web_module(igniter, app_module)

      if web_module do
        igniter
        |> create_user_channel(web_module)
        |> create_inbox_controller(web_module, otp_app)
        |> add_inbox_routes(web_module)
        |> configure_counter_broadcast(otp_app, web_module)
      else
        Igniter.add_notice(
          igniter,
          """
          ⚠️  Phoenix web module not detected. Skipping channel setup.

          You can manually create a UserChannel for real-time notifications.
          See: https://hexdocs.pm/ash_dispatch/phoenix-integration.html
          """
        )
      end
    end

    # The documented reference channel (phoenix-integration.md). The one this
    # installer used to write defined `broadcast_counter/3` and pushed
    # "counter_update", but `CounterHandler` calls the configured function
    # with four arguments and the SDK listens for "counter_updated" — so no
    # counter update ever arrived.
    defp create_user_channel(igniter, web_module) do
      channel_module = Module.concat(web_module, UserChannel)
      endpoint = inspect(Module.concat(web_module, Endpoint))

      content = """
      @moduledoc \"\"\"
      Phoenix channel for real-time user notifications and counter updates.

      Expects the socket to assign `:user_id` (and `:current_user`, which is
      the actor for marking notifications as read).

      Generated by `mix ash_dispatch.install`.
      \"\"\"

      use Phoenix.Channel

      alias AshDispatch.Helpers.{ChannelState, CounterLoader, NotificationLoader}

      @impl true
      def join("user:" <> user_id, _payload, socket) do
        if socket.assigns[:user_id] == user_id do
          send(self(), :after_join)
          {:ok, socket}
        else
          {:error, %{reason: "unauthorized"}}
        end
      end

      @impl true
      def handle_info(:after_join, socket) do
        push(socket, "initial_state", ChannelState.build(socket.assigns.user_id))
        {:noreply, socket}
      end

      @impl true
      def handle_in("refresh_counters", _payload, socket) do
        counters = CounterLoader.load_counters_for_user(socket.assigns.user_id)
        {:reply, {:ok, %{counters: counters}}, socket}
      end

      def handle_in("mark_notification_read", %{"id" => id}, socket) do
        case NotificationLoader.mark_as_read(id, actor: socket.assigns[:current_user]) do
          {:ok, _} -> {:reply, :ok, socket}
          {:error, %Ash.Error.Forbidden{}} -> {:reply, {:error, %{reason: "unauthorized"}}, socket}
          {:error, error} -> {:reply, {:error, %{reason: inspect(error)}}, socket}
        end
      end

      def handle_in("mark_all_notifications_read", _payload, socket) do
        user_id = socket.assigns.user_id

        case NotificationLoader.mark_all_as_read(user_id, actor: socket.assigns[:current_user]) do
          {:ok, _} ->
            #{endpoint}.broadcast("user:\#{user_id}", "all_notifications_read", %{})
            broadcast_counter(user_id, :unread_notifications, 0)
            {:reply, :ok, socket}

          {:error, reason} ->
            {:reply, {:error, %{reason: "failed", details: inspect(reason)}}, socket}
        end
      end

      @doc \"\"\"
      Broadcasts a counter update to the user's channel.

      Called by AshDispatch through `config :ash_dispatch, counter_broadcast_fn:`.
      \"\"\"
      def broadcast_counter(user_id, counter_name, value, opts \\\\ []) do
        #{endpoint}.broadcast("user:\#{user_id}", "counter_updated", %{
          counter: counter_name,
          value: value,
          metadata: Keyword.get(opts, :metadata, %{})
        })
      end
      """

      create_module(igniter, channel_module, content)
    end

    defp create_inbox_controller(igniter, web_module, _otp_app) do
      controller_module = Module.concat(web_module, InboxApiController)
      web_module_str = inspect(web_module)

      content = """
      @moduledoc \"\"\"
      API controller for inbox-related endpoints.

      Generated by `mix ash_dispatch.install`.
      \"\"\"

      use #{web_module_str}, :controller

      @doc \"\"\"
      Generate a socket token for the current user.

      Used by the frontend to authenticate Phoenix channel connections. Verify
      it in your socket's `connect/3` with the same salt, `"user socket"`.
      \"\"\"
      def socket_token(conn, _params) do
        user = conn.assigns[:current_user]

        if user do
          token = Phoenix.Token.sign(#{web_module_str}.Endpoint, "user socket", user.id)
          json(conn, %{success: true, data: %{token: token}})
        else
          conn
          |> put_status(:unauthorized)
          |> json(%{success: false, error: "Not authenticated"})
        end
      end
      """

      create_module(igniter, controller_module, content)
    end

    @socket_token_path "/api/inbox/socket-token"

    defp add_inbox_routes(igniter, web_module) do
      route_code = """
        # AshDispatch inbox API
        get "#{@socket_token_path}", InboxApiController, :socket_token
      """

      # `append_to_scope/4` appends unconditionally, so a second run of the
      # installer would add the route a second time. The router is read first
      # and left alone when it already has it.
      {igniter, router} = Igniter.Libs.Phoenix.select_router(igniter)

      if router && route_present?(igniter, router) do
        igniter
      else
        Igniter.Libs.Phoenix.append_to_scope(igniter, "/", route_code,
          arg2: web_module,
          placement: :after
        )
      end
    rescue
      _ ->
        Igniter.add_notice(
          igniter,
          """
          ⚠️  Could not automatically add inbox routes.

          Please add manually to your router:

              get "/api/inbox/socket-token", InboxApiController, :socket_token
          """
        )
    end

    defp route_present?(igniter, router) do
      case Igniter.Project.Module.find_module(igniter, router) do
        {:ok, {_igniter, source, _zipper}} ->
          String.contains?(Rewrite.Source.get(source, :content), @socket_token_path)

        _ ->
          false
      end
    end

    defp configure_counter_broadcast(igniter, _otp_app, web_module) do
      channel_module = Module.concat(web_module, UserChannel)

      Igniter.Project.Config.configure_new(
        igniter,
        "config.exs",
        :ash_dispatch,
        [:counter_broadcast_fn],
        {channel_module, :broadcast_counter}
      )
    end

    # ============================================
    # Email Configuration
    # ============================================

    defp maybe_configure_email(igniter, false, _otp_app, _app_module), do: igniter

    defp maybe_configure_email(igniter, true, _otp_app, app_module) do
      mailer_module = Module.concat(app_module, Mailer)

      # Check if mailer exists
      {mailer_exists?, igniter} = Igniter.Project.Module.module_exists(igniter, mailer_module)

      if mailer_exists? do
        igniter
        |> Igniter.Project.Config.configure_new(
          "config.exs",
          :ash_dispatch,
          [:email_backend],
          AshDispatch.EmailBackend.Swoosh
        )
        |> Igniter.Project.Config.configure_new(
          "config.exs",
          :ash_dispatch,
          [:swoosh_mailer],
          mailer_module
        )
      else
        Igniter.add_notice(
          igniter,
          """
          ⚠️  Mailer module #{inspect(mailer_module)} not found.

          To enable email notifications, configure Swoosh:

              config :ash_dispatch,
                email_backend: AshDispatch.EmailBackend.Swoosh,
                swoosh_mailer: #{inspect(mailer_module)}
          """
        )
      end
    end

    # ============================================
    # TypeScript SDK
    # ============================================

    defp maybe_run_typescript(igniter, false), do: igniter

    defp maybe_run_typescript(igniter, true) do
      # Check if ash_typescript is actually being used in the project
      # by checking if any domain has the AshTypescript.Rpc extension
      if ash_typescript_in_use?() do
        Igniter.add_task(igniter, "ash_dispatch.gen")
      else
        # ash_typescript not in use - just skip silently (it's optional)
        # User can run `mix ash_dispatch.gen` later if they set it up
        igniter
      end
    end

    defp ash_typescript_in_use? do
      # Check if AshTypescript.Rpc module exists
      if Code.ensure_loaded?(AshTypescript.Rpc) do
        # Check if any domain uses the AshTypescript.Rpc extension
        otp_app = Mix.Project.config()[:app]
        domains = Application.get_env(otp_app, :ash_domains, [])

        Enum.any?(domains, fn domain ->
          Code.ensure_loaded?(domain) and
            function_exported?(domain, :spark_dsl_config, 0) and
            has_ash_typescript_extension?(domain)
        end)
      else
        false
      end
    end

    defp has_ash_typescript_extension?(domain) do
      try do
        extensions = Spark.extensions(domain)
        AshTypescript.Rpc in extensions
      rescue
        _ -> false
      end
    end

    # ============================================
    # Helpers
    # ============================================

    defp detect_user_resource(igniter, app_module) do
      # Common user resource locations
      candidates = [
        Module.concat([app_module, Accounts, User]),
        Module.concat([app_module, Users, User]),
        Module.concat([app_module, User])
      ]

      Enum.find(candidates, fn module ->
        {exists?, _} = Igniter.Project.Module.module_exists(igniter, module)
        exists?
      end)
    end

    defp detect_web_module(igniter, app_module) do
      # Common web module patterns
      candidates = [
        Module.concat(app_module, Web),
        Module.concat([app_module |> to_string() |> Kernel.<>("Web") |> String.to_atom()])
      ]

      Enum.find(candidates, fn module ->
        {exists?, _} = Igniter.Project.Module.module_exists(igniter, module)
        exists?
      end)
    end

    # ============================================
    # Final Notice
    # ============================================

    defp add_final_notice(igniter, app_module, found_repo, user_resource) do
      repo_notice =
        if found_repo do
          ""
        else
          """

          ⚠️  No Ecto repo found. The resources use #{inspect(Module.concat(app_module, Repo))}
          — create it (e.g. `mix igniter.install ash_postgres`) or change their `repo:` option.
          """
        end

      user_notice =
        if user_resource do
          ""
        else
          """

          ⚠️  No user resource found, so no RecipientResolver was generated, and the
          Notification resource's user relationship is left as a comment to fill in.
          Once you have one:

              mix ash_dispatch.gen.recipient_resolver #{inspect(app_module)}.RecipientResolver \\
                --user-resource #{inspect(app_module)}.Accounts.User

              config :ash_dispatch, recipient_resolver: #{inspect(app_module)}.RecipientResolver
          """
        end

      resolver_line =
        if user_resource,
          do: "\n  - #{inspect(Module.concat(app_module, RecipientResolver))}",
          else: ""

      notice = """
      🎉 AshDispatch has been installed!

      Created:
        - #{inspect(Module.concat([app_module, Notifications, Notification]))}
        - #{inspect(Module.concat([app_module, Notifications, Preference]))}
        - #{inspect(Module.concat(app_module, Notifications))} (domain)
        - #{inspect(Module.concat([app_module, Deliveries, DeliveryReceipt]))}
        - #{inspect(Module.concat(app_module, Deliveries))} (domain)#{resolver_line}
        - priv/ash_dispatch/layouts/email.html.heex
        - priv/ash_dispatch/layouts/email.text.eex
      #{repo_notice}#{user_notice}
      Next Steps:

      1. Run migrations:
         mix ash.codegen add_ash_dispatch
         mix ash.migrate

         The preference resource needs PostgreSQL 15 or later (its scope
         identity is NULLS NOT DISTINCT). Delete it and the
         `preference_resource:`/`user_preference:` lines if you keep
         preferences somewhere else.

      2. Oban now has the queues and the two scheduled workers, written into
         config/config.exs:

           queues: [default: 10, emails: 10, sms: 5, webhooks: 5]
           plugins: [
             {Oban.Plugins.Cron,
              crontab: [
                {"*/5 * * * *", AshDispatch.Workers.RetryFailedDeliveries},
                {"0 * * * *", AshDispatch.Workers.ScrubSensitiveContent}
              ]}
           ]

         Queues and schedules you had already set were left as they were, so
         check that both workers are in fact scheduled: without them a failed
         delivery is never tried again and the bodies of sensitive messages
         are never emptied - and nothing tells you.

      3. Add events to your resources:

         defmodule #{inspect(app_module)}.Orders.Order do
           use Ash.Resource,
             extensions: [AshDispatch.Resource]

           dispatch do
             event :created,
               trigger_on: :create,
               channels: [
                 [transport: :in_app, audience: :user]
               ],
               content: [
                 notification_title: "Order Created",
                 notification_message: "Your order #\{\{id\}\} was created"
               ]
           end
         end

      4. Generate email templates (if using email channel):
         mix ash.codegen

      5. (Optional) Generate TypeScript SDK:
         mix ash_dispatch.gen

      📚 Documentation: https://hexdocs.pm/ash_dispatch
      """

      Igniter.add_notice(igniter, notice)
    end
  end
else
  defmodule Mix.Tasks.AshDispatch.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()} | Install `igniter` to use"

    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_dispatch.install' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
