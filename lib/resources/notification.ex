defmodule AshDispatch.Resources.Notification do
  @moduledoc """
  Reference documentation for Notification resources.

  **Important:** This module is a placeholder. Consuming apps must create their own
  Notification resource using the Base module.

  ## Creating Your Notification Resource

  ```elixir
  defmodule MyApp.Notifications.Notification do
    use AshDispatch.Resources.Notification.Base,
      repo: MyApp.Repo,
      domain: MyApp.Notifications,
      extensions: [AshTypescript.Resource]

    # Optional: TypeScript type generation
    typescript do
      type_name("Notification")
    end

    # Add your User relationship
    relationships do
      belongs_to :user, MyApp.Accounts.User do
        source_attribute :user_id
        destination_attribute :id
        allow_nil? false
        public? true
        define_attribute? false  # Base already defines user_id
      end
    end
  end
  ```

  ## Counter Broadcasting

  The Base module includes counter broadcasting DSL (via `AshDispatch.Resource`).
  Configure counters for real-time notification counts:

  ```elixir
  counters do
    counter :unread_notifications,
      trigger_on: [:create, :mark_as_read, :mark_all_as_read],
      query_filter: [read: false],
      audience: :user,
      invalidates: ["notifications"]
  end
  ```

  ## Configuration

  Configure your custom resource in your app:

  ```elixir
  config :ash_dispatch,
    notification_resource: MyApp.Notifications.Notification
  ```

  See `AshDispatch.Resources.Notification.Base` for full documentation.
  """

  # Minimal struct definition for internal type references.
  # Consuming apps should create their own resource using the Base module.
  defstruct [
    :id,
    :user_id,
    :type,
    :title,
    :message,
    :metadata,
    :action_label,
    :action_url,
    :source,
    :occurred_at,
    :read,
    :read_at,
    :event_id,
    :idempotency_key,
    :inserted_at,
    :updated_at
  ]
end
