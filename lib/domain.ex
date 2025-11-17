defmodule AshDispatch.Domain do
  @moduledoc """
  AshDispatch Domain for managing delivery receipts and notification resources.

  This domain contains all resources used by AshDispatch for event tracking
  and delivery management.

  ## Resources

  - `AshDispatch.Resources.DeliveryReceipt` - Tracks delivery lifecycle

  ## Usage

  Add to your application's domains if you want to query delivery receipts:

      defmodule MyApp.Application do
        use Application

        def start(_type, _args) do
          children = [
            # ...
          ]

          opts = [strategy: :one_for_one, name: MyApp.Supervisor]
          Supervisor.start_link(children, opts)
        end
      end

  """

  use Ash.Domain

  resources do
    resource AshDispatch.Resources.DeliveryReceipt
    resource AshDispatch.Resources.Notification
  end
end
