defmodule AshDispatch.Test.Order do
  @moduledoc """
  Test resource with explicit module override.
  Used to test that explicit modules are respected and not overwritten.
  """
  # ETS so records can be created and read back: `AshDispatch.PreviewTest`
  # previews a real order through the `<data_key>_id` load path.
  use Ash.Resource,
    domain: AshDispatch.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshDispatch.Resource]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :order_number, :string, allow_nil?: false, public?: true
    attribute :status, :atom, default: :pending, public?: true
  end

  actions do
    defaults [:read]

    create :create do
      accept [:order_number]
    end

    update :complete do
      accept []
    end
  end

  dispatch do
    # Event with explicit module override - should NOT generate module
    event :created,
      trigger_on: :create,
      module: AshDispatch.Test.Events.OrderCreated,
      channels: [
        [transport: :email, audience: :user]
      ]
  end
end

# Stub module for the explicit override test
defmodule AshDispatch.Test.Events.OrderCreated do
  @moduledoc false
  use AshDispatch.Event

  @impl true
  def id, do: "order.created"

  @impl true
  def resource, do: AshDispatch.Test.Order

  @impl true
  def channels(_context) do
    [
      %AshDispatch.Channel{transport: :email, audience: :user}
    ]
  end

  # One regular attachment + one inline image, exercising the
  # transport → Oban args → worker round-trip in
  # `AshDispatch.Workers.SendEmailTest`.
  @impl true
  def attachments(_context, %AshDispatch.Channel{transport: :email}) do
    [
      %{
        filename: "faktura.pdf",
        content_type: "application/pdf",
        data: "%PDF-1.4"
      },
      %{
        filename: "logo.png",
        content_type: "image/png",
        data: <<137, 80, 78, 71>>,
        type: :inline,
        cid: "logo"
      }
    ]
  end

  def attachments(_context, _channel), do: []
end
