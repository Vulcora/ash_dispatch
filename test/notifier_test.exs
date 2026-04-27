defmodule AshDispatch.NotifierTest do
  @moduledoc """
  Tests for `AshDispatch.Notifier` — the single notifier that handles
  all DispatchEvent + counter-broadcast work via Ash.Notifier's
  commit-deferred firing mechanism.

  These tests exercise the notify/1 dispatch path through real
  `Ash.create` calls on fixture resources. The companion
  `notifier_tx_semantics_test.exs` tests the
  defer-and-fire-or-drop semantics under `Ash.transaction` wraps.
  """

  use ExUnit.Case, async: false

  alias AshDispatch.Notifier
  alias AshDispatch.Notifier.Info

  describe "notify/1 — counter dispatch path" do
    setup do
      test_pid = self()

      fun = fn user_id, counter_name, count, opts ->
        send(test_pid, {:counter_broadcast, user_id, counter_name, count, opts})
        :ok
      end

      prior = Application.get_env(:ash_dispatch, :counter_broadcast_fn)
      Application.put_env(:ash_dispatch, :counter_broadcast_fn, fun)

      on_exit(fn ->
        case prior do
          nil -> Application.delete_env(:ash_dispatch, :counter_broadcast_fn)
          v -> Application.put_env(:ash_dispatch, :counter_broadcast_fn, v)
        end
      end)

      :ok
    end

    defmodule Domain do
      @moduledoc false
      use Ash.Domain, validate_config_inclusion?: false

      resources do
        allow_unregistered? true
      end
    end

    defmodule Resource do
      @moduledoc false
      use Ash.Resource,
        domain: AshDispatch.NotifierTest.Domain,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshDispatch.Resource]

      attributes do
        uuid_primary_key :id
        attribute :title, :string, public?: true
        attribute :user_id, :uuid, allow_nil?: false, public?: true
      end

      actions do
        defaults [:read]

        create :create do
          accept [:title, :user_id]
        end
      end

      counters do
        counter :test_count,
          trigger_on: :create,
          audience: :user
      end
    end

    test "counter broadcasts with expected user_id, counter_name, count" do
      user_id = Ash.UUID.generate()

      {:ok, _record} =
        Resource
        |> Ash.Changeset.for_create(:create, %{title: "test", user_id: user_id})
        |> Ash.create(authorize?: false)

      assert_receive {:counter_broadcast, ^user_id, :test_count, count, _opts}, 1000
      assert is_integer(count)
    end

    test "Notifier is auto-registered on Resource via :simple_notifiers" do
      assert Notifier in Ash.Resource.Info.notifiers(Resource)
    end

    test "counter config is persisted and readable via Info" do
      configs = Info.counter_broadcasts_for(Resource, :create)

      assert [config] = configs
      assert Keyword.get(config, :counter_name) == :test_count
      assert Keyword.get(config, :resource) == Resource
      assert Keyword.get(config, :audience) == :user
    end

    test "actions without counters return [] from counter_broadcasts_for/2" do
      assert Info.counter_broadcasts_for(Resource, :read) == []
    end
  end

  describe "notify/1 — error isolation" do
    test "raises in counter_broadcast_fn don't crash the action" do
      # Configure a broadcast fn that raises. The notifier's safe_dispatch
      # should rescue and log, not propagate.
      prior = Application.get_env(:ash_dispatch, :counter_broadcast_fn)
      Application.put_env(:ash_dispatch, :counter_broadcast_fn, fn _, _, _, _ -> raise "boom" end)

      on_exit(fn ->
        case prior do
          nil -> Application.delete_env(:ash_dispatch, :counter_broadcast_fn)
          v -> Application.put_env(:ash_dispatch, :counter_broadcast_fn, v)
        end
      end)

      ExUnit.CaptureLog.capture_log(fn ->
        # Action should succeed even though notifier raised internally.
        {:ok, _record} =
          AshDispatch.NotifierTest.Resource
          |> Ash.Changeset.for_create(:create, %{
            title: "test",
            user_id: Ash.UUID.generate()
          })
          |> Ash.create(authorize?: false)
      end)
    end
  end

  describe "notify/1 — non-action notifications" do
    test "returns :ok when notification has nil action" do
      # Defensive — Ash.Notifier may pass notifications without actions
      # in some lifecycle paths (e.g. read actions). Notifier should
      # handle gracefully.
      assert :ok = Notifier.notify(%Ash.Notifier.Notification{action: nil})
    end
  end
end
