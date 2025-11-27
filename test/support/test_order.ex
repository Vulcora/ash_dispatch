defmodule AshDispatch.Test.Order do
  @moduledoc """
  Test resource with explicit module override.
  Used to test that explicit modules are respected and not overwritten.
  """
  use Ash.Resource,
    domain: AshDispatch.Test.Domain,
    extensions: [AshDispatch.Resource]

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
end
