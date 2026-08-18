defmodule AshDispatch.Transports.PreferenceGatingTest do
  @moduledoc """
  The per-receipt gate as the transports actually run it.

  One event fanned out to two recipients with different preferences must
  produce two different outcomes: the opted-out recipient's receipt is
  `:skipped` ("user_opted_out"), the subscribed recipient's receipt is
  handed on to delivery. Before 0.6.4 the transports asked about the
  *context* user, so both receipts got the same verdict.

  Delivery itself can't complete here — the library test suite runs
  without an Oban instance and without a notification resource — so the
  non-gated side asserts what the gate is responsible for: the receipt was
  NOT skipped, i.e. it reached the delivery path.
  """
  use ExUnit.Case, async: false

  alias AshDispatch.Channel
  alias AshDispatch.Context
  alias AshDispatch.Test.TransportReceipt
  alias AshDispatch.Transports.Email
  alias AshDispatch.Transports.InApp

  @opted_out_marketing_user_id "11111111-1111-1111-1111-111111111111"
  @subscribed_user_id "22222222-2222-2222-2222-222222222222"

  defmodule MarketingOptOutChecker do
    @moduledoc false
    @behaviour AshDispatch.UserPreference

    @impl true
    def user_allows?(user_id, _event_id, _transport, opts) do
      not (opts[:category] == :marketing and
             user_id in Application.get_env(:ash_dispatch, :test_opted_out_user_ids, []))
    end
  end

  setup do
    previous_checker = Application.get_env(:ash_dispatch, :user_preference)

    Application.put_env(:ash_dispatch, :user_preference, MarketingOptOutChecker)
    Application.put_env(:ash_dispatch, :test_opted_out_user_ids, [@opted_out_marketing_user_id])

    on_exit(fn ->
      if previous_checker do
        Application.put_env(:ash_dispatch, :user_preference, previous_checker)
      else
        Application.delete_env(:ash_dispatch, :user_preference)
      end

      Application.delete_env(:ash_dispatch, :test_opted_out_user_ids)
    end)

    context = %Context{
      event_id: "mailing.sent",
      data: %{},
      # The event's subject is the opted-out customer — under the old gate
      # that verdict was applied to every recipient of the fan-out.
      user: %{id: @opted_out_marketing_user_id}
    }

    %{
      context: context,
      event_config: [metadata: [category: :marketing]]
    }
  end

  defp receipt!(user_id, transport, email) do
    TransportReceipt
    |> Ash.Changeset.for_create(:create, %{
      event_id: "mailing.sent",
      audience: :user,
      transport: transport,
      user_id: user_id,
      recipient: email,
      subject: "This week's arrivals",
      body_html: "<p>This week's arrivals</p>",
      body_text: "This week's arrivals",
      content: %{from: "news@example.com"}
    })
    |> Ash.create!(authorize?: false)
  end

  defp reload(receipt) do
    Ash.get!(TransportReceipt, receipt.id, authorize?: false)
  end

  describe "email transport" do
    test "one fan-out, two recipients: exactly one receipt is gated", ctx do
      channel = %Channel{transport: :email, audience: :user}

      opted_out = receipt!(@opted_out_marketing_user_id, :email, "optout@example.com")
      subscribed = receipt!(@subscribed_user_id, :email, "subscriber@example.com")

      assert {:ok, gated} = Email.deliver(opted_out, ctx.context, channel, ctx.event_config)
      assert gated.status == :skipped
      assert gated.error_message == "user_opted_out"

      # The subscribed recipient reaches delivery. Enqueueing can't succeed
      # without an Oban instance; what matters is that the gate let it past.
      _ = Email.deliver(subscribed, ctx.context, channel, ctx.event_config)

      refute reload(subscribed).status == :skipped
    end

    test "a receipt without a user_id is never gated (external recipient)", ctx do
      channel = %Channel{transport: :email, audience: :user}

      external = receipt!(nil, :email, "auditor@example.com")

      _ = Email.deliver(external, ctx.context, channel, ctx.event_config)

      refute reload(external).status == :skipped
    end

    test "an ungated audience delivers to an opted-out user", ctx do
      channel = %Channel{transport: :email, audience: :admin}

      receipt = receipt!(@opted_out_marketing_user_id, :email, "optout@example.com")

      _ = Email.deliver(receipt, ctx.context, channel, ctx.event_config)

      refute reload(receipt).status == :skipped
    end
  end

  describe "in_app transport" do
    test "one fan-out, two recipients: exactly one receipt is gated", ctx do
      channel = %Channel{transport: :in_app, audience: :user}

      opted_out = receipt!(@opted_out_marketing_user_id, :in_app, "optout@example.com")
      subscribed = receipt!(@subscribed_user_id, :in_app, "subscriber@example.com")

      assert {:ok, gated} = InApp.deliver(opted_out, ctx.context, channel, ctx.event_config)
      assert gated.status == :skipped
      assert gated.error_message == "user_opted_out"

      # No notification resource is configured in the library test suite, so
      # the write fails — but only after the gate has let the receipt past.
      _ = InApp.deliver(subscribed, ctx.context, channel, ctx.event_config)

      refute reload(subscribed).status == :skipped
    end
  end

  describe "structural: the delivery paths gate per receipt" do
    # Regression guard in the spirit of 0.6.1/0.6.2: a future refactor must
    # not quietly put the context-based gate back into a delivery path.
    for {transport, path} <- [
          {"email", "lib/transports/email.ex"},
          {"in_app", "lib/transports/in_app.ex"}
        ] do
      test "#{transport} transport calls allows_receipt?/4, not allows?/3" do
        source = File.read!(unquote(path))

        assert source =~ "UserPreference.allows_receipt?(receipt, context, channel, event_config)",
               "#{unquote(path)} no longer gates on the receipt's own recipient"

        refute source =~ "UserPreference.allows?(",
               "#{unquote(path)} is back to the context-based gate (the wrong-user bug)"
      end
    end
  end
end
