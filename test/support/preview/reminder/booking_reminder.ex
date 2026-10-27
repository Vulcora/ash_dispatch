defmodule AshDispatch.Test.Preview.BookingReminder do
  @moduledoc false
  # A manual event (`trigger_on: :manual`), sent through `Dispatcher.dispatch/3`
  # — the other send path a preview has to match. Its own directory, so its
  # templates are its own.
  use AshDispatch.Event

  alias AshDispatch.Channel

  @impl true
  def id, do: "booking.reminder"

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
  def subject(%{data: %{booking: booking}}, %Channel{variant: "host"}),
    do: "Guest reminder: #{booking.reference}"

  def subject(%{data: %{booking: booking}}, _channel), do: "See you soon — #{booking.reference}"

  @impl true
  def notification_title(_context, _channel), do: "Reminder sent"

  @impl true
  def notification_message(%{data: %{booking: booking}}, _channel),
    do: "Reminder for #{booking.reference}"

  # Where a real event would mint a token. Reports to the test process, so a
  # test can tell whether it ran — a preview must never run it.
  @impl true
  def generate_send_variables(_context, variables) do
    case Application.get_env(:ash_dispatch, :capture_pid) do
      pid when is_pid(pid) -> send(pid, {:minted, id()})
      _ -> :ok
    end

    {:ok, Map.put(variables, :token, "minted")}
  end

  @impl true
  def prepare_template_assigns(%{data: %{booking: booking}}, _channel) do
    %{reference: booking.reference}
  end

  @impl true
  def sample_data do
    %{
      booking: %AshDispatch.Test.Preview.Booking{
        id: "00000000-0000-0000-0000-000000000042",
        reference: "B-SAMPLE",
        guest_name: "Sample Guest",
        guest_email: "guest@example.com"
      }
    }
  end
end
