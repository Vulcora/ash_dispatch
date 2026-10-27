defmodule AshDispatch.Test.Preview.BookingBroken do
  @moduledoc false
  # A letter with everything wrong that `AshDispatch.Test.assert_all_render/1`
  # must catch: an empty subject, `#{...}` in body position (raw text under
  # EEx) and a TODO. Its own directory, so its templates are its own.
  use AshDispatch.Event

  @impl true
  def id, do: "booking.broken"

  @impl true
  def resource, do: AshDispatch.Test.Preview.Booking

  @impl true
  def data_key, do: :booking

  @impl true
  def recipients(%{data: %{booking: booking}}, _channel) do
    [%{email: booking.guest_email, name: booking.guest_name}]
  end

  def recipients(_context, _channel), do: []

  @impl true
  def subject(_context, _channel), do: ""

  @impl true
  def prepare_template_assigns(%{data: %{booking: booking}}, _channel) do
    %{reference: booking.reference}
  end

  @impl true
  def sample_data do
    %{
      booking: %AshDispatch.Test.Preview.Booking{
        id: "00000000-0000-0000-0000-000000000043",
        reference: "B-BROKEN",
        guest_name: "Broken Guest",
        guest_email: "broken@example.com"
      }
    }
  end
end
