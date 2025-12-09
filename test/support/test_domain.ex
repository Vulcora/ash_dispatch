defmodule AshDispatch.Test.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshDispatch.Test.Ticket
    resource AshDispatch.Test.Order
    resource AshDispatch.Test.DeliveryReceipt
  end
end
