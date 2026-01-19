defmodule AshDispatch.Test.CounterTestDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule AshDispatch.Test.CounterTestResource do
  @moduledoc false
  use Ash.Resource,
    domain: AshDispatch.Test.CounterTestDomain,
    data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key :id
    attribute :status, :atom
    attribute :unread_count, :integer, default: 0
    attribute :deleted_at, :utc_datetime
    attribute :user_id, :uuid
  end

  actions do
    defaults [:read, :create, :update]
  end
end
