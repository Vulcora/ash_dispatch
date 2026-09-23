# `use AshDispatch.Setup` only ever runs at compile time, inside a consuming
# app's domain module — so that is where it is exercised: these modules are
# compiled with the suite, and `test/setup_test.exs` inspects what came out.

defmodule AshDispatch.Test.Setup.Repo do
  @moduledoc false
  # Never started. AshPostgres resources only need the module to compile.
  use AshPostgres.Repo, otp_app: :ash_dispatch, warn_on_missing_ash_functions?: false

  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
end

defmodule AshDispatch.Test.Setup.User do
  @moduledoc false
  use Ash.Resource,
    domain: AshDispatch.Test.Setup.Accounts,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "users"
    repo(AshDispatch.Test.Setup.Repo)
  end

  attributes do
    uuid_primary_key :id
  end
end

defmodule AshDispatch.Test.Setup.Accounts do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshDispatch.Test.Setup.User
  end
end

defmodule AshDispatch.Test.Setup.Notification do
  @moduledoc false
  use AshDispatch.Resources.Notification.Base,
    repo: AshDispatch.Test.Setup.Repo,
    domain: AshDispatch.Test.Setup.Notifications
end

defmodule AshDispatch.Test.Setup.Notifications do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshDispatch.Test.Setup.Notification
  end
end

defmodule AshDispatch.Test.Setup.Deliveries do
  @moduledoc false

  # Written the way a consumer would, with an alias: the receipt is compiled
  # as a module of its own, so Setup has to resolve the alias here.
  alias AshDispatch.Test.Setup.User

  use AshDispatch.Setup,
    repo: AshDispatch.Test.Setup.Repo,
    notification_resource: AshDispatch.Test.Setup.Notification,
    user_resource: User

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshDispatch.Test.Setup.Deliveries.DeliveryReceipt
  end
end
