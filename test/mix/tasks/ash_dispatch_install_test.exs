defmodule Mix.Tasks.AshDispatch.InstallTest do
  # Until 0.8.4 the installer had never produced a project that compiles:
  # every module was named `MyApp..X`, every module was nested inside a second
  # copy of itself, and the resources used modules that do not exist. These
  # tests pin the properties that were broken. The CI job `installer` runs it
  # in a real project and compiles the result.
  use ExUnit.Case, async: true

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

  defp add_ash_typescript(igniter) do
    igniter
    |> Igniter.Project.Deps.add_dep({:ash_typescript, "~> 0.7"})
    |> apply_igniter!()
  end

  defp content(igniter, path) do
    assert source = igniter.rewrite.sources[path], "#{path} was not created"
    Rewrite.Source.get(source, :content)
  end

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

  test "without a user resource: no resolver, and a notice saying how to add one" do
    igniter = install([], user: false)

    refute_creates(igniter, "lib/test/recipient_resolver.ex")
    refute content(igniter, "lib/test/notifications/notification.ex") =~ ~r/^\s*belongs_to/m

    assert_has_notice(igniter, &(&1 =~ "mix ash_dispatch.gen.recipient_resolver"))
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
