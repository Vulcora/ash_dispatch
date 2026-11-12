defmodule AshDispatch.DeliveryModeTest do
  @moduledoc """
  The setting itself: how it is read, and who an allow-list lets through.

  The per-transport behaviour — that every transport actually asks — is in
  `test/delivery/delivery_mode_transports_test.exs`.
  """
  # Async disabled: every test writes :ash_dispatch application config.
  use ExUnit.Case, async: false

  alias AshDispatch.DeliveryMode

  setup do
    saved =
      for key <- [:delivery_mode, :skip_email_delivery] do
        {key, Application.get_env(:ash_dispatch, key)}
      end

    on_exit(fn ->
      for {key, value} <- saved do
        if is_nil(value),
          do: Application.delete_env(:ash_dispatch, key),
          else: Application.put_env(:ash_dispatch, key, value)
      end
    end)

    Application.delete_env(:ash_dispatch, :delivery_mode)
    Application.delete_env(:ash_dispatch, :skip_email_delivery)
    :ok
  end

  defp put(mode), do: Application.put_env(:ash_dispatch, :delivery_mode, mode)

  @transports [:email, :sms, :push, :in_app, :webhook, :slack, :discord]

  describe "the default" do
    # The versioning rule: a host on ~> 0.9.1 takes this patch and sees no
    # change until it opts in.
    test "a host that sets nothing is :live on every transport" do
      for transport <- @transports do
        assert DeliveryMode.for_transport(transport) == :live
        assert DeliveryMode.verdict(transport, "someone@example.com") == :send
      end
    end
  end

  describe "one mode for every transport" do
    test ":blocked holds back every transport, not only email" do
      put(:blocked)

      for transport <- @transports do
        assert {:skip, reason} = DeliveryMode.verdict(transport, "someone@example.com")
        assert reason == DeliveryMode.reason(:blocked)
      end
    end

    test ":dry_run holds back every transport, with its own reason" do
      put(:dry_run)

      for transport <- @transports do
        assert DeliveryMode.verdict(transport, "someone@example.com") ==
                 {:skip, DeliveryMode.reason(:dry_run)}
      end
    end

    test ":live sends on every transport" do
      put(:live)

      for transport <- @transports do
        assert DeliveryMode.verdict(transport, "someone@example.com") == :send
      end
    end

    # The three reasons must stay distinguishable: a dashboard counting what a
    # dry run would have sent must not also count what was blocked outright.
    test "the three reasons are different strings" do
      reasons = Enum.map([:blocked, :dry_run, :not_allowed], &DeliveryMode.reason/1)
      assert length(Enum.uniq(reasons)) == 3
    end
  end

  describe "per transport" do
    test "a named transport wins over :default" do
      put(default: :blocked, email: :live)

      assert DeliveryMode.verdict(:email, "a@example.com") == :send
      assert {:skip, _} = DeliveryMode.verdict(:sms, "+46701234567")
    end

    test "a transport that is not named and has no :default is :live" do
      put(email: :blocked)

      assert {:skip, _} = DeliveryMode.verdict(:email, "a@example.com")
      assert DeliveryMode.verdict(:in_app, "a@example.com") == :send
    end

    test "an allow-list can be set for one transport only" do
      put(default: :blocked, email: {:allow_list, ["ops@example.com"]})

      assert DeliveryMode.verdict(:email, "ops@example.com") == :send
      assert {:skip, _} = DeliveryMode.verdict(:email, "customer@example.com")
      assert {:skip, _} = DeliveryMode.verdict(:sms, "ops@example.com")
    end
  end

  describe "a value that is not a mode" do
    @describetag :capture_log

    # A misspelling must be reported, not turned into an outage: a library has
    # no business deciding that a host sends nothing tonight.
    test "is reported and treated as not configured" do
      put(:blockd)

      assert DeliveryMode.for_transport(:email) == :live
      assert DeliveryMode.verdict(:email, "a@example.com") == :send
    end
  end

  describe "skip_email_delivery backwards compatibility" do
    test "blocks email with the reason it has always written" do
      Application.put_env(:ash_dispatch, :skip_email_delivery, true)

      assert DeliveryMode.for_transport(:email) == :blocked

      assert DeliveryMode.verdict(:email, "a@example.com") ==
               {:skip, "email delivery disabled (dev mode)"}
    end

    test "covers email only — which is the gap this release closes" do
      Application.put_env(:ash_dispatch, :skip_email_delivery, true)

      for transport <- @transports -- [:email] do
        assert DeliveryMode.verdict(transport, "a@example.com") == :send
      end
    end

    test "false changes nothing" do
      Application.put_env(:ash_dispatch, :skip_email_delivery, false)
      assert DeliveryMode.verdict(:email, "a@example.com") == :send
    end

    # It is email-specific, so it beats a GLOBAL delivery_mode: a host that had
    # it switched on and then sets `delivery_mode: :live` must not start
    # mailing real people from a development machine.
    test "beats a global delivery_mode" do
      Application.put_env(:ash_dispatch, :skip_email_delivery, true)
      put(:live)

      assert DeliveryMode.verdict(:email, "a@example.com") ==
               {:skip, "email delivery disabled (dev mode)"}
    end

    test "an explicit email entry beats it" do
      Application.put_env(:ash_dispatch, :skip_email_delivery, true)
      put(email: :live)

      assert DeliveryMode.verdict(:email, "a@example.com") == :send
    end
  end

  describe "the allow-list" do
    test "an exact address, case ignored" do
      assert DeliveryMode.allowed?("ops@example.com", ["ops@example.com"])
      assert DeliveryMode.allowed?("OPS@Example.COM", ["ops@example.com"])
      assert DeliveryMode.allowed?("ops@example.com", ["  OPS@EXAMPLE.COM  "])
      refute DeliveryMode.allowed?("ops2@example.com", ["ops@example.com"])
    end

    test "a domain, with or without the @" do
      assert DeliveryMode.allowed?("anyone@example.test", ["@example.test"])
      assert DeliveryMode.allowed?("anyone@example.test", ["example.test"])
      refute DeliveryMode.allowed?("anyone@example.com", ["@example.test"])
      # Not a suffix match on the whole address: a lookalike domain must not pass.
      refute DeliveryMode.allowed?("anyone@notexample.test", ["@example.test"])
    end

    test "a phone prefix, separators ignored" do
      assert DeliveryMode.allowed?("+46701234567", ["+4670"])
      assert DeliveryMode.allowed?("+46 70 123 45 67", ["+4670"])
      assert DeliveryMode.allowed?("+46701234567", ["+46701234567"])
      refute DeliveryMode.allowed?("+46731234567", ["+4670"])
      # A list must use the same format as the recipients it is matched against.
      refute DeliveryMode.allowed?("0701234567", ["+4670"])
    end

    test "an explicit prefix with *" do
      assert DeliveryMode.allowed?("team-ops@example.com", ["team-*"])
      refute DeliveryMode.allowed?("ops@example.com", ["team-*"])
      assert DeliveryMode.allowed?("+46701234567", ["+4670*"])
    end

    test "* lets everything through" do
      assert DeliveryMode.allowed?("anyone@anywhere.example", ["*"])
    end

    test "any entry may match" do
      list = ["@example.test", "ops@example.com", "+4670"]

      assert DeliveryMode.allowed?("someone@example.test", list)
      assert DeliveryMode.allowed?("ops@example.com", list)
      assert DeliveryMode.allowed?("+46701234567", list)
      refute DeliveryMode.allowed?("customer@example.com", list)
    end

    # An allow-list exists so that nothing escapes. A recipient it cannot read
    # is not sent to.
    test "fails closed on an empty list and an unreadable recipient" do
      refute DeliveryMode.allowed?("ops@example.com", [])
      refute DeliveryMode.allowed?(nil, ["*"])
      refute DeliveryMode.allowed?("", ["*"])
      refute DeliveryMode.allowed?("   ", ["*"])
      refute DeliveryMode.allowed?(%{}, ["*"])
    end

    test "reads the address out of the shapes the transports pass" do
      assert DeliveryMode.allowed?({"Kim", "kim@example.test"}, ["@example.test"])
      assert DeliveryMode.allowed?(%{email: "kim@example.test"}, ["@example.test"])
      assert DeliveryMode.allowed?(%{phone: "+46701234567"}, ["+4670"])
    end

    test "the keyword spelling means the same as the tuple" do
      put(allow_list: ["ops@example.com"])

      assert DeliveryMode.for_transport(:email) == {:allow_list, ["ops@example.com"]}
      assert DeliveryMode.verdict(:email, "ops@example.com") == :send

      assert DeliveryMode.verdict(:email, "customer@example.com") ==
               {:skip, DeliveryMode.reason(:not_allowed)}
    end
  end
end
