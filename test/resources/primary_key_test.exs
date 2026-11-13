defmodule AshDispatch.Resources.PrimaryKeyTest do
  @moduledoc """
  `primary_key:` on the three `Base` macros (#50).

  `uuid_v7_primary_key` makes `mix ash.codegen` write
  `default: fragment("uuid_generate_v7()")`. That function is not built into
  Postgres before 18 — ash_postgres creates it, in the `ash-functions`
  migration, and only for a repo that asks for it. Where it is missing
  `CREATE TABLE` fails, and a host that creates a tenant's tables when the
  tenant is created cannot create a tenant at all.

  The option is the escape hatch. What is pinned here is both halves: that it
  works, and that **the defaults did not move** — a host that does not pass it
  gets the key it got in 0.9.4-rc.1, which is what keeps this a patch.
  """
  use ExUnit.Case, async: true

  alias AshDispatch.Resources.PrimaryKey

  defp id(resource), do: Ash.Resource.Info.attribute(resource, :id)

  describe "the defaults, unchanged" do
    test "Notification.Base is :uuid_v7" do
      assert id(AshDispatch.Test.Inbox.Notification).type == Ash.Type.UUIDv7
      assert id(AshDispatch.Test.Inbox.Notification).default == (&Ash.UUIDv7.generate/0)
    end

    test "Preference.Base is :uuid_v7" do
      assert id(AshDispatch.Test.Inbox.Preference).type == Ash.Type.UUIDv7
      assert id(AshDispatch.Test.Inbox.Preference).default == (&Ash.UUIDv7.generate/0)
    end

    test "DeliveryReceipt.Base is :uuid" do
      assert id(AshDispatch.Test.PerTenant.Receipt).type == Ash.Type.UUID
      assert id(AshDispatch.Test.PerTenant.Receipt).default == (&Ash.UUID.generate/0)
    end
  end

  describe "primary_key: :uuid — the host without uuid_generate_v7()" do
    test "Notification.Base writes a v4 key, whose migration default is gen_random_uuid()" do
      assert id(AshDispatch.Test.PrimaryKey.Notification).type == Ash.Type.UUID
      assert id(AshDispatch.Test.PrimaryKey.Notification).default == (&Ash.UUID.generate/0)
    end

    test "Preference.Base writes a v4 key" do
      assert id(AshDispatch.Test.PrimaryKey.Preference).type == Ash.Type.UUID
      assert id(AshDispatch.Test.PrimaryKey.Preference).default == (&Ash.UUID.generate/0)
    end

    test "the column is still a uuid, so only the DEFAULT differs" do
      assert Ash.Type.storage_type(Ash.Type.UUIDv7, []) ==
               Ash.Type.storage_type(Ash.Type.UUID, [])
    end
  end

  describe "primary_key: :uuid_v7 — the other direction" do
    test "DeliveryReceipt.Base can be asked for a v7 key" do
      assert id(AshDispatch.Test.PrimaryKey.Receipt).type == Ash.Type.UUIDv7
      assert id(AshDispatch.Test.PrimaryKey.Receipt).default == (&Ash.UUIDv7.generate/0)
    end

    test "everything else about the receipt is untouched" do
      assert id(AshDispatch.Test.PrimaryKey.Receipt).primary_key?
      assert Ash.Resource.Info.attribute(AshDispatch.Test.PrimaryKey.Receipt, :event_id)
      assert Ash.Resource.Info.attribute(AshDispatch.Test.PrimaryKey.Receipt, :status)
    end
  end

  describe "a value the base does not understand" do
    test "is named, with the two that work" do
      assert_raise ArgumentError, ~r/primary_key: :bigint/, fn ->
        PrimaryKey.attribute(:uuid_v7, :bigint)
      end

      assert_raise ArgumentError, ~r/`:uuid_v7` or `:uuid`/, fn ->
        PrimaryKey.attribute(:uuid, "uuid")
      end
    end

    test "nil is the base's own default, not an error" do
      assert PrimaryKey.attribute(:uuid_v7, nil) == PrimaryKey.attribute(:uuid_v7, :uuid_v7)
      assert PrimaryKey.attribute(:uuid, nil) == PrimaryKey.attribute(:uuid, :uuid)
      refute PrimaryKey.attribute(:uuid, nil) == PrimaryKey.attribute(:uuid_v7, nil)
    end
  end
end
