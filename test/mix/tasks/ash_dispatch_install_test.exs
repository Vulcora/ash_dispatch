defmodule Mix.Tasks.AshDispatch.InstallTest do
  # Until 0.8.4 the installer had never produced a project that compiles:
  # every module was named `MyApp..X`, every module was nested inside a second
  # copy of itself, and the resources used modules that do not exist. These
  # tests pin the properties that were broken. The CI job `installer` runs it
  # in a real project and compiles the result.
  #
  # Not async: while Igniter formats the files it writes, it evaluates the test
  # project's `config/config.exs` INTO THE REAL application environment and
  # restores it afterwards. Two such files running at the same time take each
  # other's values for the originals and restore them for good - which reached
  # the rest of the suite as a `:preference_resource` pointing at a module that
  # does not exist here.
  use ExUnit.Case, async: false

  import Igniter.Test

  @repo """
  defmodule Test.Repo do
    use AshPostgres.Repo, otp_app: :test
  end
  """

  @user """
  defmodule Test.Accounts.User do
    use Ash.Resource, domain: Test.Accounts
  end
  """

  # The repo in the shapes the `uuid_generate_v7()` check has to tell apart.
  @repo_plain """
  defmodule Test.Repo do
    use AshPostgres.Repo, otp_app: :test

    def installed_extensions, do: ["ash-functions"]
  end
  """

  @repo_15 """
  defmodule Test.Repo do
    use AshPostgres.Repo, otp_app: :test

    def installed_extensions, do: ["ash-functions"]
    def min_pg_version, do: %Version{major: 15, minor: 0, patch: 0}
  end
  """

  @repo_18 """
  defmodule Test.Repo do
    use AshPostgres.Repo, otp_app: :test

    def installed_extensions, do: ["ash-functions"]
    def min_pg_version, do: %Version{major: 18, minor: 0, patch: 0}
  end
  """

  # ash_postgres's `ash-functions` migration, as it comes out when it is
  # relying on the server's own uuidv7() — the file the first host had.
  @migration_v18 """
  defmodule Test.Repo.Migrations.InstallAshFunctions do
    use Ecto.Migration

    def up do
      execute("CREATE OR REPLACE FUNCTION ash_raise_error(json_data jsonb) RETURNS BOOLEAN AS $$ BEGIN END $$ LANGUAGE PLPGSQL")
    end
  end
  """

  # The same, generated while it was not.
  @migration_v17 """
  defmodule Test.Repo.Migrations.InstallAshFunctions do
    use Ecto.Migration

    def up do
      execute("CREATE OR REPLACE FUNCTION ash_raise_error(json_data jsonb) RETURNS BOOLEAN AS $$ BEGIN END $$ LANGUAGE PLPGSQL")
      execute("CREATE OR REPLACE FUNCTION uuid_generate_v7() RETURNS UUID AS $$ BEGIN END $$ LANGUAGE PLPGSQL")
    end
  end
  """

  @generated %{
    "lib/test/notifications/notification.ex" => Test.Notifications.Notification,
    "lib/test/notifications.ex" => Test.Notifications,
    "lib/test/deliveries/delivery_receipt.ex" => Test.Deliveries.DeliveryReceipt,
    "lib/test/deliveries.ex" => Test.Deliveries,
    "lib/test/recipient_resolver.ex" => Test.RecipientResolver
  }

  defp install(argv \\ [], opts \\ []) do
    files = %{"lib/test/repo.ex" => @repo, "lib/test/accounts/user.ex" => @user}

    files =
      if opts[:user] == false, do: Map.delete(files, "lib/test/accounts/user.ex"), else: files

    test_project(files: files)
    |> then(&if(opts[:ash_typescript], do: add_ash_typescript(&1), else: &1))
    |> Igniter.compose_task("ash_dispatch.install", ["--yes" | argv])
  end

  # The installer against a given repo source, and optionally one migration
  # already on disk.
  defp install_with(repo, migration \\ nil) do
    files = %{"lib/test/repo.ex" => repo, "lib/test/accounts/user.ex" => @user}

    files =
      if migration do
        Map.put(
          files,
          "priv/repo/migrations/20260101000000_install_ash_functions.exs",
          migration
        )
      else
        files
      end

    test_project(files: files)
    |> Igniter.compose_task("ash_dispatch.install", ["--yes"])
  end

  defp add_ash_typescript(igniter) do
    igniter
    |> Igniter.Project.Deps.add_dep({:ash_typescript, "~> 0.7"})
    |> apply_igniter!()
  end

  defp content(igniter, path) do
    assert source = igniter.rewrite.sources[path], "#{path} was not created"
    Rewrite.Source.get(source, :content)
  end

  defp notices(igniter), do: Enum.join(igniter.notices, "\n")

  defp collect(content, fun) do
    content
    |> Code.string_to_quoted!()
    |> Macro.prewalk([], fn node, acc -> {node, fun.(node, acc)} end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp defined_modules(content) do
    collect(content, fn
      {:defmodule, _, [{:__aliases__, _, parts}, _]}, acc -> [Module.concat(parts) | acc]
      {:defmodule, _, [name, _]}, acc when is_atom(name) -> [name | acc]
      _node, acc -> acc
    end)
  end

  defp used_modules(content) do
    collect(content, fn
      {:use, _, [{:__aliases__, _, parts} | _]}, acc -> [Module.concat(parts) | acc]
      _node, acc -> acc
    end)
  end

  test "each file defines exactly its own module, once" do
    igniter = install()

    for {path, module} <- @generated do
      assert defined_modules(content(igniter, path)) == [module], path
    end
  end

  test "every module the generated code uses exists" do
    igniter = install()

    for {path, _module} <- @generated, used <- used_modules(content(igniter, path)) do
      assert Code.ensure_loaded?(used), "#{path} uses #{inspect(used)}, which does not exist"
    end
  end

  test "the resources are built on the Base modules, with the project's repo and user" do
    igniter = install()

    notification = content(igniter, "lib/test/notifications/notification.ex")
    assert notification =~ "use AshDispatch.Resources.Notification.Base"
    assert notification =~ "repo: Test.Repo"
    assert notification =~ "belongs_to :user, Test.Accounts.User"

    receipt = content(igniter, "lib/test/deliveries/delivery_receipt.ex")
    assert receipt =~ "use AshDispatch.Resources.DeliveryReceipt.Base"
    assert receipt =~ "notification_resource: Test.Notifications.Notification"
    assert receipt =~ "user_resource: Test.Accounts.User"
  end

  test "configures what the runtime looks up" do
    config = install() |> content("config/config.exs")

    for expected <- [
          "repo: Test.Repo",
          "notification_resource: Test.Notifications.Notification",
          "delivery_receipt_resource: Test.Deliveries.DeliveryReceipt",
          "recipient_resolver: Test.RecipientResolver"
        ] do
      assert config =~ expected
    end
  end

  describe "TypeScript (#31)" do
    test "plain resources when the project has no ash_typescript" do
      igniter = install()

      refute content(igniter, "lib/test/notifications/notification.ex") =~ "AshTypescript"
      refute content(igniter, "lib/test/deliveries/delivery_receipt.ex") =~ "AshTypescript"
    end

    test "TypeScript resources, with type names, when it has" do
      igniter = install([], ash_typescript: true)

      notification = content(igniter, "lib/test/notifications/notification.ex")
      assert notification =~ "extensions: [AshTypescript.Resource]"
      # Parens or not depends on the project's formatter config.
      assert notification =~ ~r/type_name\(?"Notification"/

      receipt = content(igniter, "lib/test/deliveries/delivery_receipt.ex")
      assert receipt =~ "extensions: [AshTypescript.Resource]"
      assert receipt =~ ~r/type_name\(?"DeliveryReceipt"/
    end

    test "--no-typescript keeps them plain even when it has" do
      igniter = install(["--no-typescript"], ash_typescript: true)

      refute content(igniter, "lib/test/notifications/notification.ex") =~ "AshTypescript"
      refute content(igniter, "lib/test/deliveries/delivery_receipt.ex") =~ "AshTypescript"
    end
  end

  test "the closing notice names the queues and both scheduled workers" do
    igniter = install()

    for needed <- [
          "AshDispatch.Workers.RetryFailedDeliveries",
          "AshDispatch.Workers.ScrubSensitiveContent",
          "emails:",
          "sms:",
          "webhooks:",
          "Oban.Plugins.Cron"
        ] do
      assert_has_notice(igniter, &(&1 =~ needed))
    end
  end

  test "without a user resource: no resolver, and a notice saying how to add one" do
    igniter = install([], user: false)

    refute_creates(igniter, "lib/test/recipient_resolver.ex")
    refute content(igniter, "lib/test/notifications/notification.ex") =~ ~r/^\s*belongs_to/m

    assert_has_notice(igniter, &(&1 =~ "mix ash_dispatch.gen.recipient_resolver"))
  end

  # The notification and preference resources this installer writes have a
  # UUID v7 primary key, whose migration default is `uuid_generate_v7()`. A
  # repo that does not install ash_postgres's `ash-functions` never gets that
  # function, and CREATE TABLE fails — for a host that creates a tenant's
  # tables when the tenant is created, on every tenant (#50).
  describe "uuid_generate_v7()" do
    test "a repo without ash-functions is warned, with how to check and how to fix" do
      igniter = install()

      assert_has_notice(igniter, &(&1 =~ "does not list the \"ash-functions\" extension"))
      assert_has_notice(igniter, &(&1 =~ "to_regprocedure('public.uuid_generate_v7()')"))
      assert_has_notice(igniter, &(&1 =~ ~s|def installed_extensions, do: ["ash-functions"]|))
      assert_has_notice(igniter, &(&1 =~ "primary_key: :uuid"))
    end

    # The sentence the first host asked for: the source check cannot settle it,
    # and the notice must not let anyone believe it did (#50).
    test "every notice says that listing the extension is not sufficient" do
      for igniter <- [install(), install_with(@repo_18), install_with(@repo_15, @migration_v18)] do
        assert_has_notice(igniter, &(&1 =~ "Listing the extension is NOT enough"))
        assert_has_notice(igniter, &(&1 =~ "the only answer that counts"))
        assert_has_notice(igniter, &(&1 =~ "AshDispatch.Doctor.check!()"))
        assert_has_notice(igniter, &(&1 =~ "mix ash_dispatch.doctor"))
      end
    end

    test "a repo that installs them is left alone" do
      refute notices(install_with(@repo_plain)) =~ "ash-functions"
    end

    test "no repo at all: the missing-repo notice, and not this one" do
      igniter =
        test_project(files: %{"lib/test/accounts/user.ex" => @user})
        |> Igniter.compose_task("ash_dispatch.install", ["--yes"])

      assert_has_notice(igniter, &(&1 =~ "No Ecto repo found"))
      refute notices(igniter) =~ "ash-functions"
    end

    # The case rc.2's check could not see. ash_postgres emits the function only
    # when it is not relying on the server's own, which it derives from
    # `min_pg_version/0` (`major >= 18`).
    test "min_pg_version 18 is warned about even though the extension is listed" do
      igniter = install_with(@repo_18)

      assert_has_notice(igniter, &(&1 =~ "will NOT create\nuuid_generate_v7()"))
      assert_has_notice(igniter, &(&1 =~ "only on PostgreSQL 18 and later"))
      assert_has_notice(igniter, &(&1 =~ "OLDEST Postgres the application runs"))
      assert_has_notice(igniter, &(&1 =~ "postgres -V"))
    end

    test "Version.parse! is read as well as %Version{}" do
      repo = """
      defmodule Test.Repo do
        use AshPostgres.Repo, otp_app: :test

        def installed_extensions, do: ["ash-functions"]
        def min_pg_version, do: Version.parse!("18.0.0")
      end
      """

      assert_has_notice(install_with(repo), &(&1 =~ "answers 18 or more"))
    end

    # The host's own state: they lowered the answer to 17 afterwards, and the
    # migration already on disk was not rewritten.
    test "an ash-functions migration without the function is warned about" do
      igniter = install_with(@repo_15, @migration_v18)

      assert_has_notice(igniter, &(&1 =~ "does not create uuid_generate_v7()"))
      assert_has_notice(igniter, &(&1 =~ "does not rewrite a file already on disk"))
      assert_has_notice(igniter, &(&1 =~ "mix ash.codegen install_ash_functions"))
    end

    test "an ash-functions migration that does create it is left alone" do
      refute notices(install_with(@repo_15, @migration_v17)) =~ "ash-functions"
    end

    # A table migration mentions `uuid_generate_v7()` as a column DEFAULT. That
    # is the use, not the definition, and must not be mistaken for it.
    test "a column default is not mistaken for the function's definition" do
      migration = """
      defmodule Test.Repo.Migrations.AddNotifications do
        use Ecto.Migration

        def up do
          create table(:notifications, primary_key: false) do
            add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true
          end
        end
      end
      """

      igniter = install_with(@repo_15, migration)

      refute notices(igniter) =~ "does not create uuid_generate_v7()"
    end
  end

  describe "diagnose_uuid_generate_v7/2" do
    alias Mix.Tasks.AshDispatch.Install

    test "the three inputs, and what each decides" do
      assert Install.diagnose_uuid_generate_v7("use AshPostgres.Repo", :none) ==
               {:warn, :no_extension}

      assert Install.diagnose_uuid_generate_v7(@repo_15, :none) == :ok
      assert Install.diagnose_uuid_generate_v7(@repo_15, :installed_with_function) == :ok

      assert Install.diagnose_uuid_generate_v7(@repo_15, :installed_without_function) ==
               {:warn, :migration_without_function}

      # 18 wins over the migrations: it also decides what the NEXT codegen
      # writes as the column default of a new table, which an older server
      # cannot resolve either.
      assert Install.diagnose_uuid_generate_v7(@repo_18, :installed_with_function) ==
               {:warn, :builtin_assumed}
    end

    test "a repo with no min_pg_version at all is not assumed to be 18" do
      # ash_postgres assumes 13 and warns about it itself.
      assert Install.diagnose_uuid_generate_v7(@repo_plain, :none) == :ok
    end
  end

  # A minimal Phoenix web layer: `phx_test_project/1` needs the phx_new
  # archive, which neither this suite nor CI installs.
  @phoenix %{
    "lib/test_web.ex" => """
    defmodule TestWeb do
      def controller do
        quote do
          use Phoenix.Controller, formats: [:json]
        end
      end

      def router do
        quote do
          use Phoenix.Router, helpers: false
        end
      end

      defmacro __using__(which) when is_atom(which), do: apply(__MODULE__, which, [])
    end
    """,
    "lib/test_web/endpoint.ex" => """
    defmodule TestWeb.Endpoint do
      use Phoenix.Endpoint, otp_app: :test
    end
    """,
    "lib/test_web/router.ex" => """
    defmodule TestWeb.Router do
      use TestWeb, :router

      scope "/", TestWeb do
      end
    end
    """
  }

  defp created_module(igniter, module) do
    igniter.rewrite.sources
    |> Map.values()
    |> Enum.filter(&(&1.from == :string))
    |> Enum.map(&Rewrite.Source.get(&1, :content))
    |> Enum.find(&(module in defined_modules(&1))) ||
      flunk("#{inspect(module)} was not created")
  end

  test "the Phoenix channel matches what CounterHandler calls and the SDK listens for" do
    files =
      Map.merge(@phoenix, %{"lib/test/repo.ex" => @repo, "lib/test/accounts/user.ex" => @user})

    igniter =
      test_project(files: files) |> Igniter.compose_task("ash_dispatch.install", ["--yes"])

    channel = created_module(igniter, TestWeb.UserChannel)
    assert defined_modules(channel) == [TestWeb.UserChannel]
    assert channel =~ "def broadcast_counter(user_id, counter_name, value, opts \\\\ [])"
    assert channel =~ ~s("counter_updated")

    assert content(igniter, "config/config.exs") =~
             "counter_broadcast_fn: {TestWeb.UserChannel, :broadcast_counter}"

    controller = created_module(igniter, TestWeb.InboxApiController)
    assert defined_modules(controller) == [TestWeb.InboxApiController]

    assert content(igniter, "lib/test_web/router.ex") =~
             ~r/get\(?"\/api\/inbox\/socket-token", InboxApiController, :socket_token/
  end
end
