# Notification.Base on Postgres, for the :postgres test of
# `NotificationLoader.mark_all_as_read/2`. The repo is started by that test.
defmodule AshDispatch.Test.MarkAll.Repo do
  @moduledoc false
  use AshPostgres.Repo, otp_app: :ash_dispatch, warn_on_missing_ash_functions?: false

  def installed_extensions, do: []
  def min_pg_version, do: %Version{major: 15, minor: 0, patch: 0}
end

defmodule AshDispatch.Test.MarkAll.Notification do
  @moduledoc false
  use AshDispatch.Resources.Notification.Base,
    repo: AshDispatch.Test.MarkAll.Repo,
    domain: AshDispatch.Test.MarkAll.Domain,
    table: "mark_all_test_notifications"
end

defmodule AshDispatch.Test.MarkAll.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshDispatch.Test.MarkAll.Notification
  end
end
