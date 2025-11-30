defmodule AshDispatch.Domain do
  @moduledoc """
  Internal AshDispatch Domain for library-provided resources.

  This domain contains only internal resources used by AshDispatch that don't require
  database persistence. Consuming apps must create their own domain(s) for
  persisted resources like DeliveryReceipt and Notification.

  ## Internal Resources

  - `AshDispatch.Resources.EmailEvent` - Event metadata for admin UIs (ETS-backed, read-only)

  ## Consuming App Resources

  These resources must be created by consuming apps using the Base modules:

  - **DeliveryReceipt** - Use `AshDispatch.Resources.DeliveryReceipt.Base`
  - **Notification** - Use `AshDispatch.Resources.Notification.Base`
  - **ManualTrigger** - Use `AshDispatch.Resources.ManualTrigger.Base`

  See each Base module's documentation for usage instructions.
  """

  use Ash.Domain,
    validate_config_inclusion?: false

  resources do
    resource AshDispatch.Resources.EmailEvent
  end
end
