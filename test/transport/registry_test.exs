defmodule AshDispatch.Transport.RegistryTest do
  @moduledoc """
  Tests the compile-time `atom => module` registry that replaced the
  Dispatcher's hardcoded case statements (F1 — review-deep 2026-05-15).
  """

  use ExUnit.Case, async: true

  alias AshDispatch.Transport.Registry

  test "all/0 returns all 9 known transport modules" do
    all = Registry.all()
    assert length(all) == 9
    assert AshDispatch.Transports.InApp in all
    assert AshDispatch.Transports.Email in all
    assert AshDispatch.Transports.Discord in all
    assert AshDispatch.Transports.Slack in all
    assert AshDispatch.Transports.SMS in all
    assert AshDispatch.Transports.Push in all
    assert AshDispatch.Transports.Webhook in all
    assert AshDispatch.Transports.Broadcast in all
    assert AshDispatch.Transports.Oban in all
  end

  test "atoms/0 returns all transport atoms" do
    atoms = Registry.atoms() |> Enum.sort()

    assert atoms == [
             :broadcast,
             :discord,
             :email,
             :in_app,
             :oban,
             :push,
             :slack,
             :sms,
             :webhook
           ]
  end

  describe "module_for/1" do
    test "returns {:ok, module} for known atoms" do
      assert {:ok, AshDispatch.Transports.Oban} = Registry.module_for(:oban)
      assert {:ok, AshDispatch.Transports.Broadcast} = Registry.module_for(:broadcast)
      assert {:ok, AshDispatch.Transports.InApp} = Registry.module_for(:in_app)
      assert {:ok, AshDispatch.Transports.Push} = Registry.module_for(:push)
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
      assert Registry.skip_receipt?(:push) == false
      assert Registry.skip_receipt?(:webhook) == false
    end

    test "unknown atom returns false (safe default — produce a receipt)" do
      assert Registry.skip_receipt?(:nonexistent) == false
    end
  end

  describe "receipted_atoms/0" do
    # Kvitto-resursens `one_of`-constraint läser den här listan. Den var
    # tidigare hårdkodad på två ställen som glidit isär (setup.ex saknade
    # `:slack`), så en ny transport kunde producera kvitton som resursen
    # vägrade ta emot.
    test "innehåller varje transport som faktiskt skapar ett kvitto" do
      assert Registry.receipted_atoms() == [
               :discord,
               :email,
               :in_app,
               :push,
               :slack,
               :sms,
               :webhook
             ]
    end

    test "utesluter de lättviktiga transporterna" do
      refute :broadcast in Registry.receipted_atoms()
      refute :oban in Registry.receipted_atoms()
    end

    test "är exakt registret minus skip_receipt", %{} do
      förväntat =
        Registry.atoms()
        |> Enum.reject(&Registry.skip_receipt?/1)
        |> Enum.sort()

      assert Registry.receipted_atoms() == förväntat
    end
  end

  describe "Transport behaviour conformance" do
    test "every registered transport implements transport_atom/0 and skip_receipt?/0" do
      for module <- Registry.all() do
        assert Code.ensure_loaded?(module)

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
