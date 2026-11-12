defmodule Mix.Tasks.AshDispatch.InstallObanTest do
  @moduledoc """
  The installer writes the Oban configuration it used to print.

  Four releases printed "give Oban these queues and these two scheduled
  workers" in a closing notice and left it there (BACKLOG 1). A host that
  missed the notice never retried a failed delivery and never emptied a
  sensitive body — silently, which is the whole problem with a notice.

  What it must not do is clobber: a queue size someone chose, or a schedule
  someone moved, is a decision.
  """
  # Not async: see the note in `ash_dispatch_install_test.exs` - Igniter
  # evaluates the test project's config into the real application environment
  # while it formats, so two installer test files must not overlap.
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

  defp install(files \\ %{}) do
    files =
      Map.merge(%{"lib/test/repo.ex" => @repo, "lib/test/accounts/user.ex" => @user}, files)

    test_project(files: files)
    |> Igniter.compose_task("ash_dispatch.install", ["--yes"])
  end

  defp config(igniter) do
    assert source = igniter.rewrite.sources["config/config.exs"]
    Rewrite.Source.get(source, :content)
  end

  describe "a project with no Oban configuration" do
    test "gets every queue the library's workers name" do
      config = install() |> config()

      assert config =~ "queues:"

      for queue <- ["default:", "emails:", "sms:", "webhooks:"] do
        assert config =~ queue
      end
    end

    test "gets both scheduled workers" do
      config = install() |> config()

      assert config =~ "Oban.Plugins.Cron"
      assert config =~ "crontab:"
      assert config =~ "AshDispatch.Workers.RetryFailedDeliveries"
      assert config =~ "AshDispatch.Workers.ScrubSensitiveContent"
    end
  end

  describe "a project that already configures Oban" do
    @existing """
    import Config

    config :test, Oban,
      repo: Test.Repo,
      queues: [default: 3],
      plugins: [Oban.Plugins.Pruner]
    """

    setup do
      %{igniter: install(%{"config/config.exs" => @existing})}
    end

    test "keeps the queue size the host chose", %{igniter: igniter} do
      config = config(igniter)

      assert config =~ "default: 3"
      refute config =~ "default: 10"
    end

    test "adds only the queues that were missing", %{igniter: igniter} do
      config = config(igniter)

      for queue <- ["emails: 10", "sms: 5", "webhooks: 5"] do
        assert config =~ queue
      end
    end

    test "keeps the host's own plugins and adds the cron beside them", %{igniter: igniter} do
      config = config(igniter)

      assert config =~ "Oban.Plugins.Pruner"
      assert config =~ "Oban.Plugins.Cron"
      assert config =~ "AshDispatch.Workers.RetryFailedDeliveries"
      assert config =~ "AshDispatch.Workers.ScrubSensitiveContent"
    end

    test "keeps the repo it was configured with", %{igniter: igniter} do
      assert config(igniter) =~ "repo: Test.Repo"
    end
  end

  describe "a project that already has a cron plugin" do
    @with_cron """
    import Config

    config :test, Oban,
      queues: [default: 10],
      plugins: [
        {Oban.Plugins.Cron,
         crontab: [
           {"@daily", Test.Workers.Nightly}
         ]}
      ]
    """

    test "adds the two entries to the crontab the host already has" do
      config = install(%{"config/config.exs" => @with_cron}) |> config()

      assert config =~ "Test.Workers.Nightly"
      assert config =~ "AshDispatch.Workers.RetryFailedDeliveries"
      assert config =~ "AshDispatch.Workers.ScrubSensitiveContent"

      # One Cron plugin, not two.
      assert count(config, "Oban.Plugins.Cron") == 1
    end

    @moved_schedule """
    import Config

    config :test, Oban,
      queues: [default: 10],
      plugins: [
        {Oban.Plugins.Cron,
         crontab: [
           {"*/30 * * * *", AshDispatch.Workers.RetryFailedDeliveries, queue: :emails}
         ]}
      ]
    """

    # A schedule someone moved is a decision. Two entries for one worker would
    # also mean two cron jobs for it.
    test "leaves a schedule the host moved, and does not add a second entry" do
      config = install(%{"config/config.exs" => @moved_schedule}) |> config()

      assert config =~ ~s({"*/30 * * * *", AshDispatch.Workers.RetryFailedDeliveries)
      assert count(config, "AshDispatch.Workers.RetryFailedDeliveries") == 1
      assert config =~ "AshDispatch.Workers.ScrubSensitiveContent"
    end
  end

  describe "running it twice" do
    # Until now the second run stopped on "File already exists" before it got
    # anywhere, so nobody could add a resource by re-running the installer
    # after `mix igniter.install ash_postgres`.
    test "changes nothing the second time" do
      install()
      |> apply_igniter!()
      |> Igniter.compose_task("ash_dispatch.install", ["--yes"])
      |> assert_unchanged()
    end

    test "and does not duplicate the Oban configuration" do
      config =
        install()
        |> apply_igniter!()
        |> Igniter.compose_task("ash_dispatch.install", ["--yes"])
        |> apply_igniter!()
        |> config()

      assert count(config, "emails: 10") == 1
      assert count(config, "Oban.Plugins.Cron") == 1
      assert count(config, "AshDispatch.Workers.RetryFailedDeliveries") == 1
    end
  end

  describe "the preference resource" do
    test "is created, listed in the domain and configured" do
      igniter = install()

      assert content = igniter.rewrite.sources["lib/test/notifications/preference.ex"]
      preference = Rewrite.Source.get(content, :content)

      assert preference =~ "use AshDispatch.Resources.Preference.Base"
      assert preference =~ "repo: Test.Repo"
      assert preference =~ "domain: Test.Notifications"

      domain = igniter.rewrite.sources["lib/test/notifications.ex"]
      assert Rewrite.Source.get(domain, :content) =~ "Test.Notifications.Preference"

      config = config(igniter)
      assert config =~ "preference_resource: Test.Notifications.Preference"
      assert config =~ "user_preference: AshDispatch.UserPreference.Resource"
    end

    test "the notice says it needs PostgreSQL 15" do
      assert_has_notice(install(), &(&1 =~ "PostgreSQL 15"))
    end
  end

  defp count(haystack, needle) do
    haystack |> String.split(needle) |> length() |> Kernel.-(1)
  end
end
