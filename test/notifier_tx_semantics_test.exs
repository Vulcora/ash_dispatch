defmodule AshDispatch.NotifierTxSemanticsTest do
  @moduledoc """
  Canary tests for the AshDispatch tx-semantics retrofit.

  These tests are deliberately written BEFORE the substrate retrofit
  ships, with the expectation that they FAIL pre-retrofit (proving the
  bug) and PASS post-retrofit (proving the fix). The binary RED → GREEN
  flip in git history is the audit trail that the retrofit shipped
  value.

  ## The bug being canaried

  AshDispatch's `Changes.DispatchEvent` and `Changes.BroadcastCounterUpdate`
  register their work via `Ash.Changeset.after_action/2`. After-action
  callbacks fire **synchronously inside the action's transaction BEFORE
  commit/rollback**. By contrast, `Ash.transaction/2` defers
  `Ash.Notifier` notifications via `Process.put(:ash_notifications, ...)`
  and fires them post-commit (see `deps/ash/lib/ash.ex:3917-3970`).

  Pre-retrofit: a counter broadcast fires synchronously DURING the
  action, so even if a surrounding `Ash.transaction/2` rolls back, the
  broadcast already went out — phantom +1 to subscribers.

  Post-retrofit: counter broadcasts route through a single
  `AshDispatch.Notifier` (an `Ash.Notifier`-behaviour module),
  inheriting the defer-and-fire-or-drop semantics for free.

  ## Reading the test outcomes

  - **RED canary** (`refute_receive` after rollback): pre-retrofit
    FAILS because the broadcast already fired inside the txn.
    Post-retrofit PASSES because the deferred notification was dropped
    on rollback.

  - **GREEN canary** (`refute_receive` inside the txn, then
    `assert_receive` after): pre-retrofit FAILS at the inner
    `refute_receive` because the broadcast already fired. Post-retrofit
    PASSES because the notification is queued in the process dict and
    only fires when the txn commits.

  ## Tracking memory

  See `memory/project_ashdispatch_tx_semantics_gap.md` in the consuming
  Mosis app for the full architectural context. The retrofit plan
  lives at `~/.claude/plans/elegant-jingling-cray.md`.
  """

  # async: false — mutates Application.put_env(:ash_dispatch,
  # :counter_broadcast_fn, ...)
  use ExUnit.Case, async: false

  # ── Test fixture domain + resource ────────────────────────────

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
      domain: Domain,
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
      counter :tx_canary_count,
        trigger_on: :create,
        audience: :user
    end
  end

  # ── Per-test setup: register a test-pid-sending broadcast fn ──

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

  # ── The canaries ──────────────────────────────────────────────

  describe "tx-semantics canary — phantom-fire on rollback" do
    test "RED canary: counter does NOT broadcast when wrapping txn raises" do
      user_id = Ash.UUID.generate()

      # `Ash.transaction` rescues raised exceptions at `ash.ex:3955-3960`
      # and deletes `:ash_notifications` before re-raising — this is the
      # commit-deferred drop path that fires post-retrofit. Pre-retrofit,
      # `Changes.BroadcastCounterUpdate.after_action` has ALREADY called
      # `Config.counter_broadcast_fn` synchronously during the `Ash.create`
      # below, so the message is already in the mailbox by the time the
      # raise propagates and refute_receive runs.
      #
      # Note: `Ash.DataLayer.Ets` doesn't support real transactions
      # (`can?(:transact) == false`), so the inner-`{:error, _}`-as-rollback
      # path doesn't work for Ets. The raise + rescue path DOES work
      # regardless of data layer because it goes through `Ash.transaction`'s
      # outer try/rescue that always deletes the notification queue.
      assert_raise RuntimeError, ~r/deliberate-rollback/, fn ->
        Ash.transaction([Resource], fn ->
          {:ok, _record} =
            Resource
            |> Ash.Changeset.for_create(:create, %{title: "tx", user_id: user_id})
            |> Ash.create(authorize?: false)

          raise "deliberate-rollback"
        end)
      end

      # Pre-retrofit: this REFUTE FAILS — counter already fired inside the
      # txn before the raise propagated.
      #
      # Post-retrofit: the broadcast is queued via `Ash.Notifier` and the
      # `try/rescue` at `ash.ex:3955-3960` calls
      # `Process.delete(:ash_notifications)` before re-raising, so this
      # REFUTE PASSES.
      refute_receive {:counter_broadcast, _, _, _, _}, 200
    end
  end

  describe "tx-semantics canary — deferred firing on commit" do
    test "GREEN canary: counter broadcasts only AFTER commit, not inside the wrap" do
      user_id = Ash.UUID.generate()

      Ash.transaction([Resource], fn ->
        {:ok, _record} =
          Resource
          |> Ash.Changeset.for_create(:create, %{title: "tx", user_id: user_id})
          |> Ash.create(authorize?: false)

        # Pre-retrofit: this REFUTE FAILS — the broadcast already fired
        # synchronously during the after_action of `Ash.create` above.
        #
        # Post-retrofit: notifications accumulate in the process dict
        # (`Process.put(:ash_notifications, …)`); none have been drained
        # yet because the txn has not committed.
        refute_receive {:counter_broadcast, _, _, _, _}, 100

        {:ok, :done}
      end)

      # After commit (both pre- and post-retrofit): broadcast fires.
      # Pre-retrofit it fired earlier too — so this `assert_receive` passes.
      # The distinguishing assertion is the inner `refute_receive` above:
      # pre-retrofit fails it; post-retrofit passes it.
      assert_receive {:counter_broadcast, ^user_id, :tx_canary_count, _count, _opts}, 1000
    end
  end
end
