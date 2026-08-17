defmodule AshDispatch.Resources.ManualTriggerChannelSelectionTest do
  @moduledoc """
  ManualTrigger.Base must accept the CONSUMING APP's audiences and the
  registry's transports — not a library-hardcoded `one_of`.

  The old `one_of: [:user, :admin]` / `[:email, :in_app]` constraints
  silently rejected every app-defined audience (`:customers`, `:watchers`,
  permission-scoped admin audiences) and newer transports. Validation now
  happens at runtime against `config :ash_dispatch, :audiences` and
  `Transport.Registry.receipted_atoms/0`.
  """
  use ExUnit.Case, async: false

  alias AshDispatch.Resources.ManualTrigger.Helpers

  setup do
    original = Application.get_env(:ash_dispatch, :audiences)

    Application.put_env(:ash_dispatch, :audiences,
      user: [],
      admin: [:user, admin: true],
      order_admins: [
        :user,
        admin: true,
        or: [[super_admin: true], [admin_roles: [permission: :manage_orders]]]
      ],
      company_members: {SomeApp.Resolver, :company_members, [:resource]}
    )

    on_exit(fn ->
      if original do
        Application.put_env(:ash_dispatch, :audiences, original)
      else
        Application.delete_env(:ash_dispatch, :audiences)
      end
    end)

    :ok
  end

  describe "validate_channel_selection/2 — audiences" do
    test "every configured audience passes, regardless of config form" do
      assert :ok = Helpers.validate_channel_selection(:user, nil)
      assert :ok = Helpers.validate_channel_selection(:admin, nil)
      assert :ok = Helpers.validate_channel_selection(:order_admins, nil)
      # MFA-configured audiences are selectable too — the atom is known.
      assert :ok = Helpers.validate_channel_selection(:company_members, nil)
    end

    test "nil means no filter and is always valid" do
      assert :ok = Helpers.validate_channel_selection(nil, nil)
    end

    test "an unknown audience is rejected with the configured universe in the message" do
      assert {:error, message} = Helpers.validate_channel_selection(:vip_customers, nil)
      assert message =~ ":vip_customers"
      assert message =~ ":order_admins"
    end

    test "bare-atom audience config form is honored" do
      Application.put_env(:ash_dispatch, :audiences, [:user, {:admin, [:user, admin: true]}])
      assert :ok = Helpers.validate_channel_selection(:user, nil)
      assert {:error, _} = Helpers.validate_channel_selection(:order_admins, nil)
    end
  end

  describe "validate_channel_selection/2 — transports" do
    test "every receipted registry transport passes" do
      for transport <- AshDispatch.Transport.Registry.receipted_atoms() do
        assert :ok = Helpers.validate_channel_selection(nil, transport),
               "transport #{inspect(transport)} should be selectable"
      end
    end

    test "an unknown transport is rejected with the registry universe in the message" do
      assert {:error, message} = Helpers.validate_channel_selection(nil, :carrier_pigeon)
      assert message =~ ":carrier_pigeon"
      assert message =~ ":email"
    end

    test "audience errors win over transport errors (first axis first)" do
      assert {:error, message} = Helpers.validate_channel_selection(:bogus, :carrier_pigeon)
      assert message =~ "audience"
    end
  end

  describe "structural: the hardcoded one_of is gone" do
    # Regression guard in the spirit of 0.6.1: no future refactor may
    # reintroduce a library-owned audience/transport universe in ManualTrigger.Base.
    test "Base source contains no one_of on audience/transport" do
      source = File.read!("lib/resources/manual_trigger/base.ex")

      refute source =~ ~r/one_of:?\s*\[:user,\s*:admin\]/,
             "audience one_of has returned to ManualTrigger.Base"

      refute source =~ ~r/one_of:?\s*\[:email,\s*:in_app\]/,
             "transport one_of has returned to ManualTrigger.Base"
    end
  end
end
