defmodule AshDispatch.Test.Preview.BookingMinted do
  @moduledoc false
  # An event whose letter prints a variable only `generate_send_variables/2`
  # can mint — a reset link. A preview never runs that callback, so before
  # 0.9.4 the only way to show a plausible link was to smuggle it into `data`.
  # This event answers the `%{data: ..., variables: ...}` form instead.
  use AshDispatch.Event

  @impl true
  def id, do: "booking.minted"

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
  def subject(_context, _channel), do: "Your link"

  @impl true
  def generate_send_variables(_context, variables) do
    {:ok, Map.put(variables, :reset_url, "https://example.test/reset/REAL-TOKEN")}
  end

  @impl true
  def prepare_template_assigns(%{data: %{booking: booking}}, _channel) do
    %{reference: booking.reference}
  end

  @impl true
  def sample_data(_opts) do
    %{
      data: %{
        booking: %AshDispatch.Test.Preview.Booking{
          id: "00000000-0000-0000-0000-000000000044",
          reference: "B-MINTED",
          guest_name: "Minted Guest",
          guest_email: "minted@example.com"
        }
      },
      variables: %{reset_url: "https://example.test/reset/sample-token"}
    }
  end
end
