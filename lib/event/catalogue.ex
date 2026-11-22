defmodule AshDispatch.Event.Catalogue do
  @moduledoc """
  What an event is, in words, for the people who choose to send it.

  `AshDispatch.Preview.events/0` answers a technical row: an event id, a
  transport, an audience, a variant. That is the right answer for a test and
  the wrong one for a page where somebody picks a letter to send — "which of
  `bookings.reminder` and `bookings.reminder_followup` goes to the guest?" is
  not a question an event id answers. Two hosts wrote a parallel list beside
  the catalogue for exactly this, one of them around three hundred and sixty
  lines plus fifteen per event, kept in step with the DSL by hand.

  An event answers it itself, with `c:AshDispatch.Event.catalogue/0`:

      @impl true
      def catalogue do
        %{
          name: "Booking reminder",
          description: "Sent the day before a booking, to the guest.",
          trigger: "Automatically, 24 hours before the start time.",
          audience: "The guest who made the booking.",
          group: "Bookings",
          instruction: "Send this by hand only if the guest says they never got it."
        }
      end

  Every field is optional and every one is prose. `group` is what a page
  groups by; `instruction` is for the person about to press send, and is the
  one field that belongs on a page and not in a changelog.

  Anything else the callback returns is kept under `meta`, so a host moving a
  list of its own across does not have to drop its icons and sort orders at
  the door.

  An event that does not answer is still in the catalogue, with `nil` where
  this would be.
  """

  @type t :: %__MODULE__{
          name: String.t() | nil,
          description: String.t() | nil,
          trigger: String.t() | nil,
          audience: String.t() | nil,
          group: String.t() | nil,
          instruction: String.t() | nil,
          meta: map()
        }

  defstruct [:name, :description, :trigger, :audience, :group, :instruction, meta: %{}]

  @fields [:name, :description, :trigger, :audience, :group, :instruction]

  @doc """
  Normalizes what `c:AshDispatch.Event.catalogue/0` answered.

  A map or keyword list; string keys are accepted, because a host whose list
  came from JSON has them. Anything that is not a map or keyword list, and an
  answer with nothing in it, is `nil` — an event that answered nothing is the
  same as an event that did not answer.

      iex> AshDispatch.Event.Catalogue.new(%{name: "Booking reminder"})
      %AshDispatch.Event.Catalogue{name: "Booking reminder"}

      iex> AshDispatch.Event.Catalogue.new(%{})
      nil
  """
  @spec new(term()) :: t() | nil
  def new(%__MODULE__{} = catalogue), do: catalogue

  def new(answer) when is_list(answer) do
    if Keyword.keyword?(answer), do: new(Map.new(answer)), else: nil
  end

  def new(answer) when is_map(answer) do
    known =
      Map.new(@fields, fn field ->
        {field, text(Map.get(answer, field) || Map.get(answer, Atom.to_string(field)))}
      end)

    meta =
      Enum.reduce(@fields, normalize_keys(answer), fn field, acc ->
        acc |> Map.delete(field) |> Map.delete(Atom.to_string(field))
      end)

    if Enum.all?(@fields, &is_nil(Map.get(known, &1))) and map_size(meta) == 0 do
      nil
    else
      struct(__MODULE__, Map.put(known, :meta, meta))
    end
  end

  def new(_answer), do: nil

  @doc """
  The field names this struct holds, `meta` aside.
  """
  @spec fields() :: [atom()]
  def fields, do: @fields

  defp normalize_keys(map), do: Map.new(map, fn {key, value} -> {key, value} end)

  # Prose, so a value that is not a string is said as one rather than
  # dropped — an atom group or a number is somebody's intent, not a mistake.
  defp text(nil), do: nil
  defp text(""), do: nil
  defp text(value) when is_binary(value), do: value
  defp text(value) when is_atom(value), do: Atom.to_string(value)
  defp text(value) when is_number(value), do: to_string(value)
  defp text(_value), do: nil
end
