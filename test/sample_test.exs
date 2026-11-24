defmodule AshDispatch.SampleTest do
  @moduledoc """
  `AshDispatch.Sample`: the seeded `:rand`, the in-memory struct builder and
  the rolling date anchor.

  Three hosts wrote the same struct builder, two of them by pulling a
  test-data library into production to get one. It is entirely general code,
  and the only thing a host can get wrong about it is the thing that matters
  most: a struct whose relationships are `%Ash.NotLoaded{}` crashes the
  template it was built for.
  """
  use ExUnit.Case, async: false

  alias AshDispatch.Sample
  alias AshDispatch.Test.SampleThing, as: Thing

  @moduletag :capture_log

  describe "with_seed/2" do
    test "the same seed gives the same numbers" do
      draw = fn ->
        Sample.with_seed(42, fn -> Enum.map(1..5, fn _ -> :rand.uniform(1000) end) end)
      end

      assert draw.() == draw.()
    end

    test "different seeds give different numbers" do
      a = Sample.with_seed(1, fn -> :rand.uniform(1_000_000) end)
      b = Sample.with_seed(2, fn -> :rand.uniform(1_000_000) end)

      assert a != b
    end

    test "the caller's own :rand state is put back" do
      :rand.seed(:exsss, {9, 9, 9})
      mine = :rand.export_seed()

      Sample.with_seed(42, fn -> :rand.uniform(100) end)

      assert :rand.export_seed() == mine
    end

    test "a process with no :rand state gets none back" do
      Process.delete(:rand_seed)

      Sample.with_seed(42, fn -> :rand.uniform(100) end)

      assert Process.get(:rand_seed) == nil
    end

    test "the state is put back even when fun raises" do
      :rand.seed(:exsss, {7, 7, 7})
      mine = :rand.export_seed()

      assert_raise RuntimeError, fn -> Sample.with_seed(1, fn -> raise "boom" end) end

      assert :rand.export_seed() == mine
    end

    test "nil runs the function without touching :rand at all" do
      Process.delete(:rand_seed)

      assert Sample.with_seed(nil, fn -> :ok end) == :ok
      assert Process.get(:rand_seed) == nil
    end

    test "a seed that is not an integer is hashed into one" do
      assert Sample.with_seed("abc", fn -> :rand.uniform(1000) end) ==
               Sample.with_seed("abc", fn -> :rand.uniform(1000) end)
    end
  end

  describe "build/2" do
    test "fills a type-appropriate empty value for every attribute" do
      thing = Sample.build(Thing)

      assert thing.name == ""
      assert thing.slug == ""
      assert thing.count == 0
      assert thing.ratio == 0.0
      assert Decimal.equal?(thing.amount, Decimal.new(0))
      assert thing.active == false
      assert thing.payload == %{}
      assert thing.tags == []
      assert thing.secret == ""
    end

    test "uses the attribute's own default when it has a plain one" do
      assert Sample.build(Thing).status == "draft"
    end

    test "takes the first value of a one_of constraint, not nil" do
      assert Sample.build(Thing).kind == :small
    end

    test "the primary key is a real, seeded uuid" do
      thing = Sample.build(Thing, seed: 3)

      assert {:ok, _} = Ecto.UUID.cast(thing.id)
      assert Sample.build(Thing, seed: 3).id == thing.id
      assert Sample.build(Thing, seed: 4).id != thing.id
    end

    test "a required id is filled and a nullable one is left nil" do
      thing = Sample.build(Thing)

      assert {:ok, _} = Ecto.UUID.cast(thing.owner_id)
      # Filling a nullable foreign key would claim a related record exists.
      assert thing.reviewer_id == nil
    end

    test "no two id fields of one sample share an id" do
      thing = Sample.build(Thing)

      assert thing.id != thing.owner_id
    end

    test "timestamps and dates come from the anchor" do
      anchor = ~U[2026-03-01 12:00:00.000000Z]
      thing = Sample.build(Thing, anchor: anchor)

      # `create_timestamp`/`update_timestamp` are usec, so they carry the
      # anchor whole.
      assert thing.inserted_at == anchor
      assert thing.updated_at == anchor
      assert thing.starts_on == ~D[2026-03-01]
      assert thing.starts_at == DateTime.truncate(anchor, :second)
      assert thing.seen_at == anchor
    end

    test "a to-many relationship is [] and a to-one is nil — never NotLoaded" do
      thing = Sample.build(Thing)

      assert thing.children == []
      assert thing.parent == nil

      refute Enum.any?(Map.values(Map.from_struct(thing)), &match?(%Ash.NotLoaded{}, &1))
    end

    test "depth builds the to-one relationships as structs" do
      thing = Sample.build(Thing, depth: 1)

      assert %Thing{} = thing.parent
      assert thing.parent.name == ""
      # One level only, so the cycle stops here.
      assert thing.parent.parent == nil
    end

    test "depth is capped, so a self-referencing resource cannot run away" do
      thing = Sample.build(Thing, depth: 99)

      assert %Thing{} = thing.parent.parent.parent
      assert thing.parent.parent.parent.parent == nil
    end

    test ":attrs wins over everything" do
      thing =
        Sample.build(Thing,
          attrs: %{name: "Northwind", count: 7, parent: nil, children: [:whatever]}
        )

      assert thing.name == "Northwind"
      assert thing.count == 7
      assert thing.children == [:whatever]
    end

    test ":attrs takes a keyword list too" do
      assert Sample.build(Thing, attrs: [name: "Kw"]).name == "Kw"
    end

    test "private?: false leaves the non-public attributes alone" do
      assert Sample.build(Thing, private?: false).secret == nil
      assert Sample.build(Thing).secret == ""
    end

    test "it reads nothing — this resource cannot even be read" do
      # No domain and no data layer: a read raises. A build that touched one
      # would raise with it, rather than quietly returning something.
      assert_raise ArgumentError, fn -> Ash.read!(Thing, authorize?: false) end

      assert %Thing{} = Sample.build(Thing, depth: 1)
    end

    test "a module that is not a resource answers a bare struct rather than raising" do
      assert %URI{} = Sample.build(URI, attrs: %{host: "example.test"})
    end
  end

  describe "anchor/1" do
    test "is today at midnight, on the configured clock" do
      assert Sample.anchor(now: ~U[2026-11-22 13:45:09.123456Z]) == ~U[2026-11-22 00:00:00Z]
    end

    test "rounds to the unit asked for" do
      now = ~U[2026-11-22 13:45:09.123456Z]

      assert Sample.anchor(now: now, unit: :hour) == ~U[2026-11-22 13:00:00Z]
      assert Sample.anchor(now: now, unit: :minute) == ~U[2026-11-22 13:45:00Z]
      assert Sample.anchor(now: now, unit: :second) == ~U[2026-11-22 13:45:09Z]
    end

    test "rolls: it is never a date somebody hard-coded in 2024" do
      assert DateTime.compare(Sample.anchor(), ~U[2026-01-01 00:00:00Z]) == :gt
    end

    test "comes off AshDispatch.Clock, so a frozen clock freezes it" do
      previous = Application.fetch_env(:ash_dispatch, :clock)
      Application.put_env(:ash_dispatch, :clock, {__MODULE__, :frozen, []})

      on_exit(fn ->
        case previous do
          {:ok, old} -> Application.put_env(:ash_dispatch, :clock, old)
          :error -> Application.delete_env(:ash_dispatch, :clock)
        end
      end)

      assert Sample.anchor() == ~U[2026-03-01 00:00:00Z]
    end
  end

  describe "at/1 and date/1" do
    @now ~U[2026-11-22 13:45:00Z]

    test "shifts by days, hours, minutes and seconds" do
      assert Sample.at(now: @now, days: 3) == ~U[2026-11-25 00:00:00Z]
      assert Sample.at(now: @now, days: -7) == ~U[2026-11-15 00:00:00Z]
      assert Sample.at(now: @now, hours: 5) == ~U[2026-11-22 05:00:00Z]
      assert Sample.at(now: @now, minutes: 90) == ~U[2026-11-22 01:30:00Z]
    end

    test "sets a time of day after the shift" do
      assert Sample.at(now: @now, days: 3, time: ~T[14:00:00]) == ~U[2026-11-25 14:00:00Z]
    end

    test "date/1 is the same, as a Date" do
      assert Sample.date(now: @now, days: 3) == ~D[2026-11-25]
      assert Sample.date(now: @now) == ~D[2026-11-22]
    end
  end

  describe "id/3" do
    test "is a castable uuid" do
      assert {:ok, _} = Ecto.UUID.cast(Sample.id(Thing, :id, 0))
    end

    test "is deterministic in resource, field and seed" do
      assert Sample.id(Thing, :id, 1) == Sample.id(Thing, :id, 1)
      assert Sample.id(Thing, :id, 1) != Sample.id(Thing, :id, 2)
      assert Sample.id(Thing, :id, 1) != Sample.id(Thing, :owner_id, 1)
      assert Sample.id(Thing, :id, 1) != Sample.id(URI, :id, 1)
    end

    test "is a version 4, variant 1 uuid, so every parser takes it" do
      assert <<_::binary-14, "4", _::binary-4, variant::binary-1, _::binary>> =
               Sample.id(Thing, :id, 5)

      assert variant in ["8", "9", "a", "b"]
    end
  end

  @doc false
  def frozen, do: ~U[2026-03-01 09:30:00Z]
end
