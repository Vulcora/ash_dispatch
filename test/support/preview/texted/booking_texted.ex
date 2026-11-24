defmodule AshDispatch.Test.Preview.BookingTexted do
  @moduledoc false
  # An event with a template for a transport that is NOT email. Its own
  # directory, so its templates are its own: `sms.text.eex` renders, and the
  # :in_app channel has no template at all and must keep its callback.
  use AshDispatch.Event

  @impl true
  def id, do: "booking.texted"

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
  def subject(_context, _channel), do: "Texted"

  @impl true
  def notification_title(_context, _channel), do: "From the callback"

  @impl true
  def notification_message(_context, _channel), do: "Message from the callback"

  @impl true
  def prepare_template_assigns(%{data: %{booking: booking}}, _channel) do
    %{reference: booking.reference}
  end

  @impl true
  def sample_data do
    %{
      booking: %AshDispatch.Test.Preview.Booking{
        id: "00000000-0000-0000-0000-000000000045",
        reference: "B-TEXTED",
        guest_name: "Texted Guest",
        guest_email: "texted@example.com"
      }
    }
  end
end

defmodule AshDispatch.Test.Preview.BookingUntexted do
  @moduledoc false
  # The same templates directory, and this one declares NO body: no DSL
  # `notification_message`, no override. So `use AshDispatch.Event`'s
  # placeholder is all there is, and a transport template may fill it.
  #
  # It shares `templates/` with BookingTexted, which means it also sees
  # `default.text.eex` — the generic email a host writes for every event that
  # has no template of its own. A non-email body must never reach it.
  use AshDispatch.Event

  @impl true
  def id, do: "booking.untexted"

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
  def prepare_template_assigns(%{data: %{booking: booking}}, _channel) do
    # Reports that it ran, so a test can prove it is NOT called on a channel
    # with no template of its own.
    case Application.get_env(:ash_dispatch, :capture_pid) do
      pid when is_pid(pid) -> send(pid, {:assigns_prepared, id()})
      _ -> :ok
    end

    %{reference: booking.reference}
  end

  @impl true
  def sample_data do
    %{
      booking: %AshDispatch.Test.Preview.Booking{
        id: "00000000-0000-0000-0000-000000000046",
        reference: "B-UNTEXTED",
        guest_name: "Untexted Guest",
        guest_email: "untexted@example.com"
      }
    }
  end
end
