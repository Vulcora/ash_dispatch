defmodule AshDispatch.Test.Preview.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshDispatch.Test.Preview.Booking
    resource AshDispatch.Test.Preview.ManualTrigger
  end
end

defmodule AshDispatch.Test.Preview.Booking do
  @moduledoc """
  The fixture for `AshDispatch.PreviewTest` and the parity test: a resource
  whose `:create` sends a mail through the notifier, and a manual event sent
  through `Dispatcher.dispatch/3` — the two send paths a preview has to match.
  """
  use Ash.Resource,
    domain: AshDispatch.Test.Preview.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshDispatch.Resource]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :reference, :string, allow_nil?: false, public?: true
    attribute :guest_name, :string, allow_nil?: false, public?: true
    attribute :guest_email, :string, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read]

    create :create do
      accept [:reference, :guest_name, :guest_email]
    end
  end

  dispatch do
    event :confirmed,
      trigger_on: :create,
      module: AshDispatch.Test.Preview.BookingConfirmed,
      channels: [
        [transport: :email, audience: :user]
      ]

    event :reminder,
      trigger_on: :manual,
      module: AshDispatch.Test.Preview.BookingReminder,
      channels: [
        [transport: :email, audience: :user],
        [transport: :email, audience: :user, variant: "host"],
        [transport: :in_app, audience: :user]
      ]

    event :broken,
      trigger_on: :manual,
      module: AshDispatch.Test.Preview.BookingBroken,
      channels: [
        [transport: :email, audience: :user]
      ]
  end
end

defmodule AshDispatch.Test.Preview.BookingConfirmed do
  @moduledoc false
  use AshDispatch.Event

  alias AshDispatch.Channel

  @names ~w(Alva Hugo Maja Elias Saga Nils)

  @impl true
  def id, do: "booking.confirmed"

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
  def subject(%{data: %{booking: booking}}, _channel),
    do: "Booking #{booking.reference} confirmed"

  @impl true
  def from(_context, _channel), do: {"Bookings", "bookings@example.com"}

  @impl true
  def reply_to(_context, %Channel{transport: :email}), do: "host@example.com"

  @impl true
  def headers(%{data: %{booking: booking}}, %Channel{transport: :email}) do
    %{"X-Entity-Ref-ID" => booking.reference}
  end

  @impl true
  def attachments(%{data: %{booking: booking}}, %Channel{transport: :email}) do
    [
      %{
        filename: "booking.ics",
        content_type: "text/calendar",
        data: "BEGIN:VCALENDAR\r\nSUMMARY:#{booking.reference}\r\nEND:VCALENDAR\r\n"
      }
    ]
  end

  def attachments(_context, _channel), do: []

  @impl true
  def prepare_template_assigns(%{data: %{booking: booking}} = context, _channel) do
    recipient = context.variables[:recipient]

    %{
      greeting: "Hi #{(recipient && recipient.name) || booking.guest_name}",
      reference: booking.reference
    }
  end

  # Drawn from `:rand`, which `AshDispatch.Preview` seeds — so the same seed
  # gives the same guest without the event doing anything about it.
  @impl true
  def sample_data(seed: _seed) do
    name = Enum.random(@names)

    %{
      booking: %AshDispatch.Test.Preview.Booking{
        id: "00000000-0000-0000-0000-00000000000#{:rand.uniform(9)}",
        reference: "B-#{:rand.uniform(9000) + 999}",
        guest_name: name,
        guest_email: "#{String.downcase(name)}@example.com"
      }
    }
  end
end

defmodule AshDispatch.Test.CaptureBackend do
  @moduledoc """
  Email backend that hands every send to the process named in
  `config :ash_dispatch, :capture_pid` — the params exactly as `SendEmail`
  built them.
  """

  def send_email(params) do
    case Application.get_env(:ash_dispatch, :capture_pid) do
      pid when is_pid(pid) -> send(pid, {:sent_email, params})
      _ -> :ok
    end

    {:ok, %{id: "captured_#{System.unique_integer([:positive])}"}}
  end
end
