defmodule Mix.Tasks.AshDispatch.GenSdkTest do
  @moduledoc """
  The off switch for the generated React/TypeScript SDK (#50).

  The first per-tenant host had `ash_typescript` for its own RPC types, no
  AshDispatch events, and no use for a React client — and got thirteen files
  it had not asked for, a `.prettierignore` section, and warnings about two
  npm packages it does not depend on. `sdk_output_path: false`, the obvious
  guess, was swallowed by an `||` chain and read as "unset", so the SDK was
  written anyway and `--check` then failed if the files were deleted.

  What is pinned here is the whole decision, not the config read: with the SDK
  off, nothing is written and `--check` passes with an empty directory.
  """
  # Not async: every test here sets `config :ash_dispatch` keys that the
  # generator reads out of the real application environment.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.AshDispatch.Gen

  @moduletag :tmp_dir

  # An app that exists only here. Nothing sets `:ash_domains` for it, so
  # `AshDispatch.Introspection` finds no events for it either — which is the
  # host in the report: `ash_typescript` configured, zero events.
  @otp_app :ash_dispatch_sdk_test

  # Every static file the SDK writes for a host with nothing of its own in it.
  @static_sdk ~w(
    store.ts channel.ts socket-provider.tsx index.ts
    hooks/use-channel.ts hooks/use-user-channel.ts hooks/use-counter.ts
    hooks/use-notifications.ts notification-provider.tsx notification-bell.tsx
    README.md
  )

  setup %{tmp_dir: tmp_dir} do
    keys = [:sdk, :sdk_output_path, :domains]
    previous = Map.new(keys, &{&1, Application.fetch_env(:ash_dispatch, &1)})
    previous_scoped = Application.fetch_env(@otp_app, :ash_dispatch)
    # `AshDispatch.Introspection` reads the app's OWN `:ash_domains` and not
    # `config :ash_dispatch, :domains`, so an events test has to set that one.
    previous_domains = Application.fetch_env(@otp_app, :ash_domains)

    # `package.json` here makes this directory the "frontend root": it is what
    # `.prettierignore` is written beside, and without it that half of the
    # generator would be skipped for reasons of its own rather than ours.
    File.write!(Path.join(tmp_dir, "package.json"), ~s({"dependencies": {}}\n))

    # The generator adds `config :ash_dispatch, :domains` to the host's own
    # domains, so an empty list here is what makes this app eventless.
    Application.put_env(:ash_dispatch, :domains, [])

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> restore(:ash_dispatch, key, value) end)
      restore(@otp_app, :ash_dispatch, previous_scoped)
      restore(@otp_app, :ash_domains, previous_domains)
    end)

    %{sdk_dir: Path.join([tmp_dir, "src", "lib", "ash-dispatch"])}
  end

  defp restore(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore(app, key, :error), do: Application.delete_env(app, key)

  defp generate(opts \\ []) do
    capture_io(fn -> send(self(), {:result, Gen.generate(@otp_app, opts)}) end)
    assert_received {:result, result}
    result
  end

  defp written(dir) do
    if File.dir?(dir) do
      dir |> Path.join("**/*") |> Path.wildcard() |> Enum.reject(&File.dir?/1)
    else
      []
    end
  end

  describe "on (the default, and what every release before 0.9.4-rc.2 did)" do
    setup %{sdk_dir: sdk_dir} do
      Application.put_env(:ash_dispatch, :sdk_output_path, sdk_dir)
      :ok
    end

    test "a host with no events still gets the whole static client", %{
      sdk_dir: sdk_dir,
      tmp_dir: tmp_dir
    } do
      assert {:ok, []} = generate()

      for file <- @static_sdk do
        assert File.exists?(Path.join(sdk_dir, file)), "#{file} was not generated"
      end

      assert File.exists?(Path.join(tmp_dir, ".prettierignore"))
    end

    test "--check fails while the files are missing", %{sdk_dir: sdk_dir} do
      assert_raise Ash.Error.Framework.PendingCodegen, fn -> generate(check: true) end

      # And it is the SDK that it is asking for, not something else.
      assert written(sdk_dir) == []
    end

    test "--check passes once they have been generated", %{sdk_dir: sdk_dir} do
      generate()
      assert written(sdk_dir) != []

      assert {:ok, []} = generate(check: true)
    end
  end

  describe "off: config :ash_dispatch, sdk: false" do
    setup %{sdk_dir: sdk_dir} do
      Application.put_env(:ash_dispatch, :sdk_output_path, sdk_dir)
      Application.put_env(:ash_dispatch, :sdk, false)
      :ok
    end

    test "generates nothing at all", %{sdk_dir: sdk_dir, tmp_dir: tmp_dir} do
      assert {:ok, []} = generate()

      assert written(sdk_dir) == []
      refute File.exists?(Path.join(tmp_dir, ".prettierignore"))
    end

    test "--check passes with no files on disk", %{sdk_dir: sdk_dir} do
      assert {:ok, []} = generate(check: true)
      assert written(sdk_dir) == []
    end

    test "--check still passes after the host deletes the files it had", %{sdk_dir: sdk_dir} do
      File.mkdir_p!(sdk_dir)
      File.write!(Path.join(sdk_dir, "channel.ts"), "// left over from before\n")
      File.rm!(Path.join(sdk_dir, "channel.ts"))

      assert {:ok, []} = generate(check: true)
    end

    test "--dry-run says nothing is coming", %{sdk_dir: sdk_dir} do
      output = capture_io(fn -> Gen.generate(@otp_app, dry_run: true) end)

      refute output =~ "ash-dispatch"
      assert written(sdk_dir) == []
    end
  end

  describe "off: config :ash_dispatch, sdk_output_path: false" do
    # The spelling the first host guessed. Before 0.9.4-rc.2 `false` was read
    # as "no explicit path", the path was derived from ash_typescript's
    # `output_file` instead, and the SDK was generated.
    setup do
      Application.put_env(:ash_dispatch, :sdk_output_path, false)
      :ok
    end

    test "generates nothing, with ash_typescript configured", %{tmp_dir: tmp_dir} do
      previous = Application.fetch_env(:ash_typescript, :output_file)
      on_exit(fn -> restore(:ash_typescript, :output_file, previous) end)

      Application.put_env(
        :ash_typescript,
        :output_file,
        Path.join([tmp_dir, "src", "lib", "ash_rpc.ts"])
      )

      assert {:ok, []} = generate()

      assert written(Path.join([tmp_dir, "src", "lib", "ash-dispatch"])) == []
      refute File.exists?(Path.join(tmp_dir, ".prettierignore"))
      assert {:ok, []} = generate(check: true)
    end
  end

  describe "opt-in: config :ash_dispatch, sdk: :if_events" do
    setup %{sdk_dir: sdk_dir} do
      Application.put_env(:ash_dispatch, :sdk_output_path, sdk_dir)
      Application.put_env(:ash_dispatch, :sdk, :if_events)
      :ok
    end

    test "a host with nothing to describe generates nothing", %{sdk_dir: sdk_dir} do
      assert {:ok, []} = generate()

      assert written(sdk_dir) == []
      assert {:ok, []} = generate(check: true)
    end

    test "a host with something to describe gets the SDK", %{sdk_dir: sdk_dir} do
      Application.put_env(:ash_dispatch, :domains, [AshDispatch.Test.SdkDomain])

      assert_raise Ash.Error.Framework.PendingCodegen, fn -> generate(check: true) end

      assert {:ok, []} = generate()

      for file <- @static_sdk ++ ["resources.ts"] do
        assert File.exists?(Path.join(sdk_dir, file)), "#{file} was not generated"
      end

      assert {:ok, []} = generate(check: true)
    end

    # The report from the host that took rc.2: `:if_events` was `:always` for
    # them, because `Notification.Base` declares the `unread_notifications`
    # counter and rc.2 counted every counter it found. "Something to generate
    # for" means something the HOST declared (#50).
    test "the three bases and nothing else: still nothing", %{sdk_dir: sdk_dir} do
      Application.put_env(:ash_dispatch, :domains, [AshDispatch.Test.SdkBases.Domain])

      assert {:ok, []} = generate()

      assert written(sdk_dir) == []
      assert {:ok, []} = generate(check: true)
    end

    test "the bases' counter is found — it just does not decide this" do
      Application.put_env(:ash_dispatch, :domains, [AshDispatch.Test.SdkBases.Domain])

      output = capture_io(fn -> Gen.generate(@otp_app, verbose: true) end)

      # The number rc.2 printed, which is still true.
      assert output =~ "Found 0 events, 1 counters"
      # And the sentence that explains why it generated nothing anyway.
      assert output =~ "come from AshDispatch's own bases"
      assert output =~ "SDK generation disabled"
    end

    test "one counter of the host's own: the SDK", %{sdk_dir: sdk_dir} do
      Application.put_env(:ash_dispatch, :domains, [AshDispatch.Test.SdkOwnCounter.Domain])

      assert_raise Ash.Error.Framework.PendingCodegen, fn -> generate(check: true) end

      assert {:ok, []} = generate()

      for file <- @static_sdk ++ ["types.ts"] do
        assert File.exists?(Path.join(sdk_dir, file)), "#{file} was not generated"
      end

      # And the base's counter is still described in it: what counts as a
      # reason to generate changed, not what is generated.
      types = File.read!(Path.join(sdk_dir, "types.ts"))
      assert types =~ "open_tickets"
      assert types =~ "unread_notifications"
    end

    test "one event of the host's own: the SDK", %{sdk_dir: sdk_dir} do
      Application.put_env(@otp_app, :ash_domains, [AshDispatch.Test.SdkOneEvent.Domain])

      assert_raise Ash.Error.Framework.PendingCodegen, fn -> generate(check: true) end

      assert {:ok, []} = generate()

      for file <- @static_sdk ++ ["events.ts"] do
        assert File.exists?(Path.join(sdk_dir, file)), "#{file} was not generated"
      end

      # The id the generator derives from the resource and the event name.
      assert File.read!(Path.join(sdk_dir, "events.ts")) =~ "ticket.opened"
    end
  end

  # `true` and `false` must be exactly what they were. A host that uses the
  # in-app bell needs the client FOR the base's counter — `NotificationBell`
  # and `useNotifications` read it — so `sdk: true` is how that host says so,
  # and `:if_events` is the wrong switch for it.
  describe "true and false are unchanged" do
    test "sdk: true generates for a host with only the bases", %{sdk_dir: sdk_dir} do
      Application.put_env(:ash_dispatch, :sdk_output_path, sdk_dir)
      Application.put_env(:ash_dispatch, :sdk, true)
      Application.put_env(:ash_dispatch, :domains, [AshDispatch.Test.SdkBases.Domain])

      assert {:ok, []} = generate()

      for file <- @static_sdk do
        assert File.exists?(Path.join(sdk_dir, file)), "#{file} was not generated"
      end
    end

    test "sdk: false generates nothing for a host with its own counter", %{sdk_dir: sdk_dir} do
      Application.put_env(:ash_dispatch, :sdk_output_path, sdk_dir)
      Application.put_env(:ash_dispatch, :sdk, false)
      Application.put_env(:ash_dispatch, :domains, [AshDispatch.Test.SdkOwnCounter.Domain])

      assert {:ok, []} = generate()
      assert written(sdk_dir) == []
    end
  end

  describe "AshDispatch.Resources.Base" do
    alias AshDispatch.Resources.Base

    test "names what each base declared, so the host's own can be told apart" do
      assert Base.counters(AshDispatch.Test.SdkBases.Notification) == [:unread_notifications]
      assert Base.counters(AshDispatch.Test.SdkBases.Preference) == []
      assert Base.counters(AshDispatch.Test.SdkBases.Receipt) == []

      assert Base.counter?(AshDispatch.Test.SdkBases.Notification, :unread_notifications)
      refute Base.counter?(AshDispatch.Test.SdkBases.Notification, :open_tickets)
    end

    test "a resource the host wrote itself declares nothing of ours" do
      assert Base.counters(AshDispatch.Test.SdkOwnCounter.Ticket) == []
      refute Base.counter?(AshDispatch.Test.SdkOwnCounter.Ticket, :open_tickets)
    end

    test "a module that is not a resource at all is not an error" do
      assert Base.counters(Enum) == []
      assert Base.counters(AshDispatch.Test.NoSuchModule) == []
    end
  end

  describe "sdk_setting/1" do
    test "defaults to :always" do
      assert Gen.sdk_setting(@otp_app) == :always
    end

    test "reads the app-scoped spelling too" do
      Application.put_env(@otp_app, :ash_dispatch, sdk: false)
      assert Gen.sdk_setting(@otp_app) == :off

      Application.put_env(@otp_app, :ash_dispatch, sdk_output_path: false)
      assert Gen.sdk_setting(@otp_app) == :off
    end

    test "names a value it does not understand" do
      Application.put_env(:ash_dispatch, :sdk, :maybe)

      assert_raise ArgumentError, ~r/sdk: :maybe/, fn -> Gen.sdk_setting(@otp_app) end
    end
  end
end
