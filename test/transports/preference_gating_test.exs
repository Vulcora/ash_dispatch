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

  describe "structural: the verdict is per receipt, never per context" do
    # Widened in 0.7.0. The guard used to demand the literal
    # `allows_receipt?/4` call inside email.ex and in_app.ex. When the six
    # copied gate blocks were replaced by one shared function the guard went
    # red — while the property it exists to protect was untouched. It was
    # measuring where the call is written, not what the call decides.
    #
    # It now measures the decision: no delivery path may derive consent from
    # `context.user`, and every path that decides at all passes the RECEIPT
    # first. The list of files is globbed rather than maintained, because a
    # maintained list is the other half of the same failure — a transport
    # added tomorrow is covered without anyone remembering to add it.
    @vagar Path.wildcard("lib/transports/*.ex")

    # Without this, every assertion below is green by iterating nothing.
    test "the glob actually found the transports" do
      assert length(@vagar) >= 8, "expected the transport directory, got #{inspect(@vagar)}"
    end

    test "no delivery path gates on the context user" do
      fel = Enum.filter(@vagar, &(File.read!(&1) =~ "UserPreference.allows?("))

      assert fel == [], """
      These paths are back to the context-based gate:

        #{inspect(fel)}

      `allows?/3` reads `context.user` — the event's SUBJECT. A fan-out has
      one receipt per recipient, so that verdict gets applied to all N of
      them: the subject's opt-out silences everybody, and the subject's
      consent overrides everybody else's no. That was the 0.6.1 bug.
      """
    end

    test "every consent decision is made from the receipt" do
      # Two forms are legitimate: asking directly, or delegating to the
      # shared gate. Both pass `receipt` first — that is the property.
      fel =
        Enum.filter(@vagar, fn vag ->
          src = File.read!(vag)
          namner? = src =~ "allows_receipt?" or src =~ "with_consent"

          ratt? =
            src =~ "with_consent(receipt, context, channel, event_config" or
              src =~ "allows_receipt?(receipt, context, channel, event_config)"

          namner? and not ratt?
        end)

      assert fel == [], """
      These decide consent, but not from the receipt's own recipient:

        #{inspect(fel)}

      Pass the receipt first — either `Preferences.with_consent(receipt,
      context, channel, event_config, fn -> ... end)` or, if you have a
      reason not to use the shared gate, `UserPreference.allows_receipt?/4`.
      """
    end

    test "the shared gate itself asks per receipt" do
      # Everything above trusts this one line, so it is asserted directly:
      # widen the indirection and the property has to survive at the end of it.
      assert File.read!("lib/transports/preferences.ex") =~
               "UserPreference.allows_receipt?(receipt, context, channel, event_config)"
    end
  end

  describe "the transports gated for the first time in 0.7.0" do
    # `:slack`, `:discord`, `:sms` and `:push` delivered regardless of
    # preferences until now. The structural guards above prove the call is
    # written; these prove it RUNS — a source guard cannot tell the
    # difference between a gate and a gate behind a condition that is never
    # true.
    #
    # Only the gated side is asserted: the opted-out receipt must be skipped.
    # The other side needs an Oban instance (slack, discord) or a configured
    # backend (sms, push), neither of which exists in the library suite —
    # and "was not skipped" is already covered for email and in_app above.
    for {transport, modul} <- [
          {:slack, AshDispatch.Transports.Slack},
          {:discord, AshDispatch.Transports.Discord},
          {:sms, AshDispatch.Transports.SMS},
          {:push, AshDispatch.Transports.Push}
        ] do
      test "#{transport}: an opted-out recipient is skipped, not delivered to", ctx do
        channel = %Channel{transport: unquote(transport), audience: :user}
        receipt = receipt!(@opted_out_marketing_user_id, unquote(transport), "optout@example.com")

        assert {:ok, gated} =
                 unquote(modul).deliver(receipt, ctx.context, channel, ctx.event_config)

        assert gated.status == :skipped
        assert gated.error_message == "user_opted_out"
      end

      test "#{transport}: an ungated audience is not silenced by the new gate", ctx do
        # The gate must not become a blanket mute. `:admin` is outside
        # `preference_gated_audiences`, so an opted-out user still gets it.
        #
        # The assertion is on the REASON, not on `:skipped`. These four
        # transports skip for legitimate reasons of their own in a suite with
        # no Oban and no backends — "transport_not_implemented", "No
        # webhook_url configured". Asserting `refute status == :skipped`
        # measured "was skipped at all" and failed on a gate that behaved
        # perfectly. The property is: the CONSENT gate did not stop it.
        channel = %Channel{transport: unquote(transport), audience: :admin}
        receipt = receipt!(@opted_out_marketing_user_id, unquote(transport), "optout@example.com")

        _ = unquote(modul).deliver(receipt, ctx.context, channel, ctx.event_config)

        refute reload(receipt).error_message == "user_opted_out"
      end
    end
  end
end
