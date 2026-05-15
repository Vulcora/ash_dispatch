defmodule AshDispatch.Transport.RegistryTest do
  @moduledoc """
  Tests the compile-time `atom => module` registry that replaced the
  Dispatcher's hardcoded case statements (F1 — review-deep 2026-05-15).
  """

  use ExUnit.Case, async: true

  alias AshDispatch.Transport.Registry

  test "all/0 returns all 8 known transport modules" do
    all = Registry.all()
    assert length(all) == 8
    assert AshDispatch.Transports.InApp in all
    assert AshDispatch.Transports.Email in all
    assert AshDispatch.Transports.Discord in all
    assert AshDispatch.Transports.Slack in all
    assert AshDispatch.Transports.SMS in all
    assert AshDispatch.Transports.Webhook in all
    assert AshDispatch.Transports.Broadcast in all
    assert AshDispatch.Transports.Oban in all
  end

  test "atoms/0 returns all transport atoms" do
    atoms = Registry.atoms() |> Enum.sort()
    assert atoms == [:broadcast, :discord, :email, :in_app, :oban, :slack, :sms, :webhook]
  end

  describe "module_for/1" do
    test "returns {:ok, module} for known atoms" do
      assert {:ok, AshDispatch.Transports.Oban} = Registry.module_for(:oban)
      assert {:ok, AshDispatch.Transports.Broadcast} = Registry.module_for(:broadcast)
      assert {:ok, AshDispatch.Transports.InApp} = Registry.module_for(:in_app)
    end

    test "returns :error for unknown atom" do
      assert :error = Registry.module_for(:nonexistent)
      assert :error = Registry.module_for(:not_a_transport)
    end
  end

  describe "skip_receipt?/1" do
    test "lightweight transports return true" do
      assert Registry.skip_receipt?(:broadcast) == true
      assert Registry.skip_receipt?(:oban) == true
    end

    test "receipted transports return false" do
      assert Registry.skip_receipt?(:in_app) == false
      assert Registry.skip_receipt?(:email) == false
      assert Registry.skip_receipt?(:discord) == false
      assert Registry.skip_receipt?(:slack) == false
      assert Registry.skip_receipt?(:sms) == false
      assert Registry.skip_receipt?(:webhook) == false
    end

    test "unknown atom returns false (safe default — produce a receipt)" do
      assert Registry.skip_receipt?(:nonexistent) == false
    end
  end

  describe "Transport behaviour conformance" do
    test "every registered transport implements transport_atom/0 and skip_receipt?/0" do
      for module <- Registry.all() do
        assert function_exported?(module, :transport_atom, 0),
               "#{inspect(module)} missing transport_atom/0"

        assert function_exported?(module, :skip_receipt?, 0),
               "#{inspect(module)} missing skip_receipt?/0"

        assert function_exported?(module, :deliver, 4),
               "#{inspect(module)} missing deliver/4"
      end
    end

    test "every transport's atom matches the Registry key" do
      for module <- Registry.all() do
        atom = module.transport_atom()
        assert {:ok, ^module} = Registry.module_for(atom),
               "Registry mismatch for #{inspect(module)} (atom: #{inspect(atom)})"
      end
    end
  end
end
