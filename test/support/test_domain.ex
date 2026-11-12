defmodule AshDispatch.Test.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshDispatch.Test.Ticket
    resource AshDispatch.Test.Order
    resource AshDispatch.Test.DeliveryReceipt
    resource AshDispatch.Test.TransportReceipt
    resource AshDispatch.Test.LegacyReceipt
    resource AshDispatch.Test.StrictReceipt
  end
end
