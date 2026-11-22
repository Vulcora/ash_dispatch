defmodule AshDispatch.Sample do
  @moduledoc """
  Three pieces of entirely general code that no host should have to own:
  a seeded `:rand` that gives the caller's state back, an in-memory Ash struct
  built from a resource's own attributes and relationships, and a date anchor
  that rolls with the calendar.

  All three exist because `c:AshDispatch.Event.sample_data/0` has to answer a
  struct, and there are only two ways to get one: read a real record (which a
  preview must not, and which an empty database cannot) or build one. Three
  hosts wrote the same struct builder, two of them by pulling a test-data
  library into production to get it.

  Nothing here reads or writes anything. `build/2` touches no data layer, runs
  no action and resolves no relationship: it reads the resource's own
  declarations and fills a struct.

  ## A sample letter

      @impl true
      def sample_data(seed: seed) do
        AshDispatch.Sample.with_seed(seed, fn ->
          %{
            booking: AshDispatch.Sample.build(MyApp.Bookings.Booking,
              attrs: %{
                reference: "B-#{:rand.uniform(9999)}",
                starts_at: AshDispatch.Sample.at(days: 3, time: ~T[14:00:00])
              }
            )
          }
        end)
      end

  ## Why a date anchor

  A sample letter that says "your booking on 3 March 2024" looks broken
  forever, and every host that hard-coded a date in its sample data has one.
  `anchor/1` is today, on the clock the library is configured with
  (`AshDispatch.Clock`), rounded down — so a preview is stable within the day
  and still moves with the calendar, and a snapshot test that freezes the
  clock gets a fixed answer.
  """

  alias Ash.Resource.Info

  require Logger

  @doc """
  Seeds the process's `:rand` with `seed` for `fun`, and puts the previous
  state back afterwards.

  A preview must not leave its caller's random numbers predictable, and an
  event's sample data must give the same letter for the same seed. Both of
  those are this function.

  `nil` runs `fun` without touching `:rand` at all.

      AshDispatch.Sample.with_seed(42, fn -> :rand.uniform(100) end)
      #=> the same number every time
  """
  @spec with_seed(integer() | nil, (-> result)) :: result when result: term()
  def with_seed(nil, fun), do: fun.()

  def with_seed(seed, fun) when is_integer(seed) do
    previous = :rand.export_seed()
    :rand.seed(:exsss, {seed, seed, seed})

    try do
      fun.()
    after
      case previous do
        :undefined -> Process.delete(:rand_seed)
        state -> :rand.seed(state)
      end
    end
  end

  def with_seed(other, fun), do: with_seed(:erlang.phash2(other), fun)

  @doc """
  Builds an in-memory struct of `resource` from its own attributes and
  relationships.

  No read, no write, no action, no relationship resolved. Every attribute is
  SET — a template that prints `@booking.reference` gets a value of the right
  type rather than `nil` by accident or `%Ash.NotLoaded{}` by omission — and
  every relationship is set to something renderable: `[]` for a to-many, `nil`
  for a to-one.

  ## What each attribute gets

  1. the value in `:attrs`, when you named it;
  2. a seeded id for the primary key, and for any other `:uuid` attribute:
     deterministic for the same resource, seed and field, so the same sample
     has the same ids every time;
  3. the anchor for `inserted_at`, `updated_at`, `created_at`;
  4. the attribute's own `default`, when it has a plain one;
  5. a type-appropriate empty value: `""`, `0`, `0.0`, `false`, `%{}`, `[]`,
     the anchor for a date or time, `Decimal.new(0)`;
  6. `nil` for a type the library does not know.

  ## Options

  - `:attrs` - a map or keyword list of values to use instead of the above
  - `:seed` - the seed the ids are derived from. `0` by default
  - `:anchor` - the `DateTime` timestamps and dates get. `anchor/1` by default
  - `:depth` - how many levels of to-one relationships to build as structs
    rather than `nil`. `0` by default; `1` is what a template reaching
    `@booking.guest.name` needs. Capped at 3
  - `:private?` - `true` also fills attributes that are not `public?`.
    `true` by default: a template renders from the struct, not from the API

  ## Example

      AshDispatch.Sample.build(MyApp.Bookings.Booking,
        attrs: %{reference: "B-1001"},
        depth: 1
      )
  """
  @spec build(module(), keyword()) :: struct()
  def build(resource, opts \\ []) do
    seed = Keyword.get(opts, :seed, 0)
    anchor = Keyword.get(opts, :anchor) || anchor()
    depth = opts |> Keyword.get(:depth, 0) |> min(3) |> max(0)
    attrs = opts |> Keyword.get(:attrs, %{}) |> to_map()
    private? = Keyword.get(opts, :private?, true)

    values =
      resource
      |> attributes(private?)
      |> Map.new(fn attribute ->
        {attribute.name, attribute_value(resource, attribute, attrs, seed, anchor)}
      end)
      |> Map.merge(relationship_values(resource, attrs, seed, anchor, depth))
      # Anything in `:attrs` that is neither an attribute nor a relationship is
      # still set: an event's template may read a calculation, or a key the
      # host put on the struct itself.
      |> Map.merge(attrs)

    struct(resource, values)
  rescue
    error ->
      Logger.warning(
        "[AshDispatch] Sample.build(#{inspect(resource)}) fell back to a bare struct: " <>
          Exception.message(error)
      )

      struct(resource, to_map(Keyword.get(opts, :attrs, %{})))
  end

  @doc """
  Today, on the configured clock, rounded down.

  A sample letter has to carry dates, and a hard-coded one is wrong from the
  week it is written. This is the one to carry instead.

  ## Options

  - `:unit` - what to round down to: `:day` (the default), `:hour`, `:minute`
    or `:second`
  - `:now` - the instant to round, instead of asking `AshDispatch.Clock`

      AshDispatch.Sample.anchor()
      #=> ~U[2026-11-22 00:00:00Z]
  """
  @spec anchor(keyword()) :: DateTime.t()
  def anchor(opts \\ []) do
    now = Keyword.get(opts, :now) || AshDispatch.Clock.utc_now()
    now = %{now | microsecond: {0, 0}}

    case Keyword.get(opts, :unit, :day) do
      :day -> %{now | hour: 0, minute: 0, second: 0}
      :hour -> %{now | minute: 0, second: 0}
      :minute -> %{now | second: 0}
      _ -> now
    end
  end

  @doc """
  The anchor, shifted, and optionally at a time of day.

  ## Options

  Everything `anchor/1` takes, plus:

  - `:days`, `:hours`, `:minutes`, `:seconds` - offsets, which may be negative
  - `:time` - a `Time` to set, after the shift

      # Three days from now, at two in the afternoon
      AshDispatch.Sample.at(days: 3, time: ~T[14:00:00])

      # A week ago
      AshDispatch.Sample.at(days: -7)
  """
  @spec at(keyword()) :: DateTime.t()
  def at(opts \\ []) do
    seconds =
      Keyword.get(opts, :days, 0) * 86_400 +
        Keyword.get(opts, :hours, 0) * 3600 +
        Keyword.get(opts, :minutes, 0) * 60 +
        Keyword.get(opts, :seconds, 0)

    shifted = DateTime.add(anchor(opts), seconds, :second)

    case Keyword.get(opts, :time) do
      %Time{} = time ->
        %{shifted | hour: time.hour, minute: time.minute, second: time.second}

      _ ->
        shifted
    end
  end

  @doc """
  `at/1` as a `Date`.

      AshDispatch.Sample.date(days: 3)
      #=> ~D[2026-11-25]
  """
  @spec date(keyword()) :: Date.t()
  def date(opts \\ []), do: DateTime.to_date(at(opts))

  @doc """
  A deterministic UUID for `resource`, `field` and `seed`.

  The same three give the same id every time, and no two fields of one sample
  share one. A real v4 string, so it casts as a `:uuid` and prints as an id
  rather than as a placeholder somebody has to explain.
  """
  @spec id(module() | term(), atom(), integer()) :: String.t()
  def id(resource, field \\ :id, seed \\ 0) do
    <<a::32, b::16, _::4, c::12, _::2, d::62, _::binary>> =
      :crypto.hash(:sha256, "ash_dispatch.sample|#{inspect(resource)}|#{field}|#{seed}")

    # Version 4, variant 1: a string every UUID parser accepts.
    <<a::32, b::16, 4::4, c::12, 2::2, d::62>>
    |> uuid_string()
  end

  # ── Attributes ──────────────────────────────────────────────────────

  defp attributes(resource, private?) do
    resource
    |> Info.attributes()
    |> Enum.filter(fn attribute -> private? or attribute.public? end)
  end

  defp attribute_value(resource, attribute, attrs, seed, anchor) do
    name = attribute.name

    cond do
      Map.has_key?(attrs, name) ->
        Map.fetch!(attrs, name)

      seeded_id?(attribute) ->
        id(resource, name, seed)

      name in [:inserted_at, :updated_at, :created_at] ->
        cast_time(attribute, anchor)

      true ->
        case plain_default(attribute) do
          {:ok, value} -> value
          :none -> empty(attribute, anchor)
        end
    end
  end

  # The primary key always, and any other id the resource says must be there.
  # A NULLABLE foreign key stays nil: filling it would claim a related record
  # exists, and `nil` is both the honest answer and a renderable one.
  defp seeded_id?(%{type: type} = attribute) when type in [Ash.Type.UUID, Ash.Type.UUIDv7] do
    Map.get(attribute, :primary_key?, false) or Map.get(attribute, :allow_nil?) == false
  end

  defp seeded_id?(_attribute), do: false

  # Only a default that is a plain value. A `{m, f, a}` or a function default
  # is the resource's business at write time, and calling it here would be the
  # read or write this module promises not to do.
  defp plain_default(%{default: default})
       when is_binary(default) or is_number(default) or is_boolean(default) or
              is_atom(default) do
    if is_nil(default), do: :none, else: {:ok, default}
  end

  defp plain_default(%{default: %{__struct__: _} = default}), do: {:ok, default}
  defp plain_default(%{default: default}) when is_map(default), do: {:ok, default}
  defp plain_default(%{default: default}) when is_list(default), do: {:ok, default}
  defp plain_default(_attribute), do: :none

  defp empty(%{type: {:array, _}}, _anchor), do: []

  defp empty(%{type: type} = attribute, anchor) do
    case type do
      Ash.Type.String -> ""
      Ash.Type.CiString -> ""
      # An atom with a `one_of` is somebody's enum; the first value is a far
      # better empty than nil, because a template printing a status wants one.
      Ash.Type.Atom -> enum_or_nil(attribute)
      Ash.Type.Integer -> 0
      Ash.Type.Float -> 0.0
      Ash.Type.Decimal -> Decimal.new(0)
      Ash.Type.Boolean -> false
      Ash.Type.Map -> %{}
      Ash.Type.Keyword -> []
      Ash.Type.Term -> nil
      Ash.Type.Binary -> ""
      Ash.Type.UUID -> nil
      Ash.Type.Date -> DateTime.to_date(anchor)
      Ash.Type.Time -> DateTime.to_time(anchor)
      Ash.Type.TimeUsec -> DateTime.to_time(anchor)
      Ash.Type.NaiveDatetime -> DateTime.to_naive(anchor)
      Ash.Type.DateTime -> anchor
      Ash.Type.UtcDatetime -> DateTime.truncate(anchor, :second)
      Ash.Type.UtcDatetimeUsec -> anchor
      _ -> enum_or_nil(attribute)
    end
  end

  defp cast_time(%{type: type}, anchor) do
    case type do
      Ash.Type.UtcDatetime -> DateTime.truncate(anchor, :second)
      Ash.Type.NaiveDatetime -> DateTime.to_naive(anchor)
      _ -> anchor
    end
  end

  # An `Ash.Type.Enum` of the host's own, or a `one_of` constraint: the first
  # value is a far better empty than nil, because a template that prints a
  # status wants a status.
  defp enum_or_nil(%{type: type, constraints: constraints}) do
    cond do
      is_atom(type) and function_exported?(type, :values, 0) ->
        List.first(type.values())

      is_list(constraints) and is_list(constraints[:one_of]) ->
        List.first(constraints[:one_of])

      true ->
        nil
    end
  rescue
    _ -> nil
  end

  defp enum_or_nil(_attribute), do: nil

  # ── Relationships ───────────────────────────────────────────────────

  # Never `%Ash.NotLoaded{}`: that is the value a template crashes on, and the
  # whole reason a host needs this function.
  defp relationship_values(resource, attrs, seed, anchor, depth) do
    resource
    |> Info.relationships()
    |> Enum.reject(&Map.has_key?(attrs, &1.name))
    |> Map.new(fn relationship ->
      {relationship.name, relationship_value(relationship, seed, anchor, depth)}
    end)
  end

  defp relationship_value(%{cardinality: :many}, _seed, _anchor, _depth), do: []

  defp relationship_value(%{destination: destination} = relationship, seed, anchor, depth)
       when depth > 0 do
    build(destination,
      seed: seed + :erlang.phash2(relationship.name, 1_000),
      anchor: anchor,
      depth: depth - 1
    )
  rescue
    _ -> nil
  end

  defp relationship_value(_relationship, _seed, _anchor, _depth), do: nil

  # ── Helpers ─────────────────────────────────────────────────────────

  defp to_map(value) when is_map(value), do: value

  defp to_map(value) when is_list(value) do
    if Keyword.keyword?(value), do: Map.new(value), else: %{}
  end

  defp to_map(_value), do: %{}

  defp uuid_string(<<a::binary-4, b::binary-2, c::binary-2, d::binary-2, e::binary-6>>) do
    [a, b, c, d, e] |> Enum.map_join("-", &Base.encode16(&1, case: :lower))
  end
end
