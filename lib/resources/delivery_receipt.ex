defmodule AshDispatch.Resources.DeliveryReceipt do
  @moduledoc """
  Unified delivery tracking for all transports (email, in-app, Discord, SMS, etc).

  This resource uses `AshDispatch.Resources.DeliveryReceipt.Base` as the single source
  of truth for all attributes, actions, calculations, and policies.

  ## For Consuming Apps

  If you need to add relationships (e.g., to your User resource), use the Base module
  directly in your own resource:

      defmodule MyApp.Deliveries.DeliveryReceipt do
        use AshDispatch.Resources.DeliveryReceipt.Base,
          repo: MyApp.Repo,
          domain: MyApp.Deliveries,
          notification_resource: MyApp.Notifications.Notification

        relationships do
          belongs_to :user, MyApp.Accounts.User do
            source_attribute :user_id
            destination_attribute :id
            allow_nil? true
            public? true
          end
        end
      end

  ## State Machine

  Tracks delivery lifecycle:
  - :pending → Initial state when receipt is created
  - :scheduled → Oban job has been enqueued
  - :sending → Actively being delivered
  - :sent → Successfully delivered
  - :failed → Delivery failed (temporary, can retry)
  - :failed_permanent → Delivery failed permanently (no retry)
  - :skipped → Delivery was intentionally skipped

  ## Content Storage

  All message content (subject, body, embeds, etc.) is stored in the receipt at creation time.
  This enables debugging, retry without re-rendering, and historical audit trails.
  """

  # Use the Base module - single source of truth for all DSL
  use AshDispatch.Resources.DeliveryReceipt.Base,
    repo: Application.compile_env(:ash_dispatch, :repo, nil),
    domain: AshDispatch.Domain,
    notification_resource: AshDispatch.Resources.Notification

  # TypeScript type name override
  typescript do
    type_name("DeliveryReceipt")
  end
end
