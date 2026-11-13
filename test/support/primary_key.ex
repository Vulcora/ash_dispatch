defmodule AshDispatch.Test.PrimaryKey.Domain do
  @moduledoc """
  The three bases built with `primary_key:` set the other way round, so the
  option can be read off a compiled resource rather than trusted.

  ETS, because nothing here is ever run: what the tests ask is what the
  resource's `:id` attribute says, which is what `mix ash.codegen` turns into
  the column's DEFAULT.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshDispatch.Test.PrimaryKey.Notification
    resource AshDispatch.Test.PrimaryKey.Preference
    resource AshDispatch.Test.PrimaryKey.Receipt
  end
end

defmodule AshDispatch.Test.PrimaryKey.Notification do
  @moduledoc false
  # Default is :uuid_v7; this host's database has no uuid_generate_v7().
  use AshDispatch.Resources.Notification.Base,
    repo: AshDispatch.Test.Setup.Repo,
    domain: AshDispatch.Test.PrimaryKey.Domain,
    data_layer: Ash.DataLayer.Ets,
    primary_key: :uuid
end

defmodule AshDispatch.Test.PrimaryKey.Preference do
  @moduledoc false
  use AshDispatch.Resources.Preference.Base,
    repo: AshDispatch.Test.Setup.Repo,
    domain: AshDispatch.Test.PrimaryKey.Domain,
    data_layer: Ash.DataLayer.Ets,
    primary_key: :uuid
end

defmodule AshDispatch.Test.PrimaryKey.Receipt do
  @moduledoc false
  # The other direction: this base defaults to :uuid, and a host that wants
  # time-ordered receipt ids (and has the function) asks for v7.
  use AshDispatch.Resources.DeliveryReceipt.Base,
    repo: AshDispatch.Test.Setup.Repo,
    domain: AshDispatch.Test.PrimaryKey.Domain,
    notification_resource: AshDispatch.Test.PrimaryKey.Notification,
    primary_key: :uuid_v7
end
