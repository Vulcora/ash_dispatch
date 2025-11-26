defmodule AshDispatch.Domain do
  @moduledoc """
  AshDispatch Domain for managing delivery receipts and notification resources.

  This domain contains all resources used by AshDispatch for event tracking
  and delivery management.

  ## Resources

  - `AshDispatch.Resources.DeliveryReceipt` - Tracks delivery lifecycle
  - `AshDispatch.Resources.Notification` - In-app notifications

  ## Embedded Resources

  These resources should be added to consuming application domains, not this library domain:

  - `AshDispatch.Resources.EmailEvent` - Event metadata for admin UIs (ETS-backed)
  - `AshDispatch.Resources.ManualTrigger` - Manual event triggering for admin UIs (embedded)

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

  use Ash.Domain,
    validate_config_inclusion?: false

  resources do
    resource AshDispatch.Resources.DeliveryReceipt
    resource AshDispatch.Resources.Notification
    resource AshDispatch.Resources.EmailEvent
  end
end
