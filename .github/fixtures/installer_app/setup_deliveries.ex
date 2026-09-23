# Copied into lib/ after the installer has run, since it needs the generated
# Notification: `use AshDispatch.Setup` in an app without ash_typescript.
defmodule Demo.SetupDeliveries do
  use AshDispatch.Setup,
    repo: Demo.Repo,
    notification_resource: Demo.Notifications.Notification,
    user_resource: Demo.Accounts.User,
    table: "setup_delivery_receipts"

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource Demo.SetupDeliveries.DeliveryReceipt
  end
end
