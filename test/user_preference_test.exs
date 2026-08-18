defmodule AshDispatch.UserPreferenceTest do
  @moduledoc """
  The preference gate: WHO it asks about, WHICH audiences it covers, and
  that the old context-based entry point still answers exactly as before.

  Before 0.6.4 the transports asked `allows?/3`, which reads the user from
  the *context* — the event's subject. On a fan-out (one event, N receipts)
  that single verdict was applied to every recipient: one customer's
  opt-out silenced everybody else's mail, or one customer's opt-in leaked
  mail to people who had opted out. The gate now runs per receipt.
  """
  # Async disabled: these tests swap the configured preference checker and
  # the gated-audience list.
  use ExUnit.Case, async: false

  alias AshDispatch.Channel
  alias AshDispatch.Config
  alias AshDispatch.Context
  alias AshDispatch.UserPreference

  @opted_out_marketing_user_id "11111111-1111-1111-1111-111111111111"
  @subscribed_user_id "22222222-2222-2222-2222-222222222222"

  defmodule OptOutChecker do
    @moduledoc false
    @behaviour AshDispatch.UserPreference

    @impl true
    def user_allows?(user_id, event_id, transport, opts) do
      # The checker runs in the caller's process, so the test can inspect
      # both the verdict and the arguments it was reached with.
      send(self(), {:preference_checked, user_id, event_id, transport, opts})

      user_id not in Application.get_env(:ash_dispatch, :test_opted_out_user_ids, [])
    end
  end

  setup do
    previous_checker = Application.get_env(:ash_dispatch, :user_preference)
    previous_gated = Application.get_env(:ash_dispatch, :preference_gated_audiences)

    Application.put_env(:ash_dispatch, :user_preference, OptOutChecker)
    Application.put_env(:ash_dispatch, :test_opted_out_user_ids, [@opted_out_marketing_user_id])

    on_exit(fn ->
      restore(:user_preference, previous_checker)
      restore(:preference_gated_audiences, previous_gated)
      Application.delete_env(:ash_dispatch, :test_opted_out_user_ids)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:ash_dispatch, key)
  defp restore(key, value), do: Application.put_env(:ash_dispatch, key, value)

  defp user_id_of(nil), do: nil
  defp user_id_of(%{id: id}), do: id
  defp user_id_of(user), do: user

  describe "allows_user?/4" do
    test "delegates the verdict to the configured checker" do
      refute UserPreference.allows_user?(@opted_out_marketing_user_id, "mailing.sent", :email,
               category: :marketing
             )

      assert UserPreference.allows_user?(@subscribed_user_id, "mailing.sent", :email,
               category: :marketing
             )
    end

    test "a nil user_id is allowed without consulting the checker" do
      assert UserPreference.allows_user?(nil, "mailing.sent", :email, category: :marketing)

      refute_received {:preference_checked, _, _, _, _}
    end

    test "opts default to an empty list" do
      assert UserPreference.allows_user?(@subscribed_user_id, "orders.created", :email)

      assert_received {:preference_checked, _, _, _, opts}
      assert opts[:category] == nil
      assert opts[:audience] == nil
    end

    test "hands the checker the category, the audience and the event id" do
      UserPreference.allows_user?(@subscribed_user_id, "mailing.sent", :email,
        category: :marketing,
        audience: :customers
      )

      assert_received {:preference_checked, @subscribed_user_id, "mailing.sent", :email, opts}
      assert opts[:category] == :marketing
      assert opts[:audience] == :customers
      assert opts[:event_id] == "mailing.sent"
    end

    test "extra opts are passed through to the checker" do
      UserPreference.allows_user?(@subscribed_user_id, "mailing.sent", :email,
        digest_mode: :daily
      )

      assert_received {:preference_checked, _, _, _, opts}
      assert opts[:digest_mode] == :daily
    end

    test "falls back to the allow-all default when no checker is configured" do
      Application.delete_env(:ash_dispatch, :user_preference)

      assert Config.user_preference() == AshDispatch.UserPreference.Default

      assert UserPreference.allows_user?(@opted_out_marketing_user_id, "mailing.sent", :email,
               category: :marketing
             )
    end
  end

  describe "allows?/3 — equivalence with the extracted predicate" do
    @user_shapes [
      nil,
      %{id: @opted_out_marketing_user_id},
      %{id: @subscribed_user_id},
      @opted_out_marketing_user_id,
      @subscribed_user_id,
      42
    ]

    test "agrees with allows_user?/4 across users, transports and categories" do
      for user <- @user_shapes,
          transport <- [:email, :in_app, :sms],
          category <- [nil, :marketing, :transactional] do
        context = %Context{event_id: "orders.created", data: %{}, user: user}
        channel = %Channel{transport: transport, audience: :user}
        event_config = [metadata: [category: category]]

        expected =
          UserPreference.allows_user?(user_id_of(user), "orders.created", transport,
            category: category,
            audience: :user
          )

        assert UserPreference.allows?(context, channel, event_config) == expected,
               "allows?/3 and allows_user?/4 disagreed for " <>
                 inspect(user: user, transport: transport, category: category)
      end
    end

    test "both entry points reach the checker with identical arguments" do
      context = %Context{
        event_id: "mailing.sent",
        data: %{},
        user: %{id: @subscribed_user_id}
      }

      channel = %Channel{transport: :email, audience: :user}
      event_config = [metadata: [category: :marketing]]

      UserPreference.allows?(context, channel, event_config)
      assert_received {:preference_checked, user_id, event_id, transport, opts_from_allows}

      UserPreference.allows_user?(@subscribed_user_id, "mailing.sent", :email,
        category: :marketing,
        audience: :user
      )

      assert_received {:preference_checked, ^user_id, ^event_id, ^transport, opts_from_predicate}

      assert opts_from_allows == opts_from_predicate
    end

    test "an event_config without metadata yields a nil category" do
      context = %Context{event_id: "orders.created", data: %{}, user: %{id: @subscribed_user_id}}
      channel = %Channel{transport: :email, audience: :user}

      assert UserPreference.allows?(context, channel, [])
      assert_received {:preference_checked, _, _, _, opts}
      assert opts[:category] == nil
    end

    test "a map event_config with map metadata resolves the category too" do
      context = %Context{event_id: "orders.created", data: %{}, user: %{id: @subscribed_user_id}}
      channel = %Channel{transport: :email, audience: :user}

      assert UserPreference.allows?(context, channel, %{metadata: %{category: :billing}})
      assert_received {:preference_checked, _, _, _, opts}
      assert opts[:category] == :billing
    end

    test "an ungated audience is allowed without consulting the checker" do
      context = %Context{
        event_id: "orders.created",
        data: %{},
        user: %{id: @opted_out_marketing_user_id}
      }

      assert UserPreference.allows?(context, %Channel{transport: :email, audience: :admin}, [])
      refute_received {:preference_checked, _, _, _, _}
    end
  end

  describe "allows_receipt?/4 — one verdict per recipient" do
    setup do
      context = %Context{
        event_id: "mailing.sent",
        data: %{},
        # The event subject happens to be the opted-out customer.
        user: %{id: @opted_out_marketing_user_id}
      }

      %{
        context: context,
        channel: %Channel{transport: :email, audience: :user},
        event_config: [metadata: [category: :marketing]]
      }
    end

    test "one fan-out with two recipients produces two verdicts", ctx do
      opted_out_receipt = %{
        id: "receipt-1",
        user_id: @opted_out_marketing_user_id,
        recipient: "optout@example.com"
      }

      subscribed_receipt = %{
        id: "receipt-2",
        user_id: @subscribed_user_id,
        recipient: "subscriber@example.com"
      }

      refute UserPreference.allows_receipt?(
               opted_out_receipt,
               ctx.context,
               ctx.channel,
               ctx.event_config
             )

      assert UserPreference.allows_receipt?(
               subscribed_receipt,
               ctx.context,
               ctx.channel,
               ctx.event_config
             )

      # The bug this replaced: the context-based gate answers for the event
      # subject, so BOTH receipts inherited the opted-out customer's verdict.
      refute UserPreference.allows?(ctx.context, ctx.channel, ctx.event_config)
    end

    test "the receipt's user wins even when the context has no user at all", ctx do
      context = %{ctx.context | user: nil}

      receipt = %{id: "receipt-3", user_id: @opted_out_marketing_user_id}

      refute UserPreference.allows_receipt?(receipt, context, ctx.channel, ctx.event_config)
      # …while the context-based gate has nobody to ask and allows everything.
      assert UserPreference.allows?(context, ctx.channel, ctx.event_config)
    end

    test "a receipt without user_id is delivered (external recipient)", ctx do
      receipt = %{id: "receipt-4", user_id: nil, recipient: "auditor@example.com"}

      assert UserPreference.allows_receipt?(receipt, ctx.context, ctx.channel, ctx.event_config)
      refute_received {:preference_checked, _, _, _, _}
    end

    test "the checker is asked about the recipient, with the event's category", ctx do
      receipt = %{id: "receipt-5", user_id: @subscribed_user_id}

      assert UserPreference.allows_receipt?(receipt, ctx.context, ctx.channel, ctx.event_config)

      assert_received {:preference_checked, @subscribed_user_id, "mailing.sent", :email, opts}
      assert opts[:category] == :marketing
      assert opts[:audience] == :user
    end

    test "event_config defaults to an empty list", ctx do
      receipt = %{id: "receipt-6", user_id: @subscribed_user_id}

      assert UserPreference.allows_receipt?(receipt, ctx.context, ctx.channel)
      assert_received {:preference_checked, _, _, _, opts}
      assert opts[:category] == nil
    end
  end

  describe "preference_gated_audiences" do
    test "defaults to [:user] — exactly the pre-0.6.4 gate" do
      Application.delete_env(:ash_dispatch, :preference_gated_audiences)

      assert Config.preference_gated_audiences() == [:user]
      assert UserPreference.gated_audience?(:user)
      refute UserPreference.gated_audience?(:customers)
      refute UserPreference.gated_audience?(:admin)
    end

    test "an ungated audience delivers to an opted-out user, unasked" do
      Application.delete_env(:ash_dispatch, :preference_gated_audiences)

      context = %Context{event_id: "mailing.sent", data: %{}, user: nil}
      channel = %Channel{transport: :email, audience: :customers}
      receipt = %{id: "receipt-7", user_id: @opted_out_marketing_user_id}

      assert UserPreference.allows_receipt?(receipt, context, channel,
               metadata: [category: :marketing]
             )

      refute_received {:preference_checked, _, _, _, _}
    end

    test "adding :customers gates that audience without touching the others" do
      Application.put_env(:ash_dispatch, :preference_gated_audiences, [:user, :customers])

      context = %Context{event_id: "mailing.sent", data: %{}, user: nil}
      customers_channel = %Channel{transport: :email, audience: :customers}
      admin_channel = %Channel{transport: :email, audience: :admin}
      event_config = [metadata: [category: :marketing]]

      opted_out_receipt = %{id: "receipt-8", user_id: @opted_out_marketing_user_id}
      subscribed_receipt = %{id: "receipt-9", user_id: @subscribed_user_id}

      refute UserPreference.allows_receipt?(
               opted_out_receipt,
               context,
               customers_channel,
               event_config
             )

      assert UserPreference.allows_receipt?(
               subscribed_receipt,
               context,
               customers_channel,
               event_config
             )

      # The admin audience stays ungated: an operator must not be able to
      # silence an operational alert by unticking a marketing box.
      assert UserPreference.allows_receipt?(
               opted_out_receipt,
               context,
               admin_channel,
               event_config
             )

      assert UserPreference.gated_audience?(:customers)
      refute UserPreference.gated_audience?(:admin)
    end
  end
end
