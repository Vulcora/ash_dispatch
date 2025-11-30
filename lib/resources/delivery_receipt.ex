defmodule AshDispatch.Resources.DeliveryReceipt do
  @moduledoc """
  Reference documentation for DeliveryReceipt resources.

  **Important:** This module is a placeholder. Consuming apps must create their own
  DeliveryReceipt resource using the Base module.

  ## Creating Your DeliveryReceipt Resource

  ```elixir
  defmodule MyApp.Deliveries.DeliveryReceipt do
    use AshDispatch.Resources.DeliveryReceipt.Base,
      repo: MyApp.Repo,
      domain: MyApp.Deliveries,
      notification_resource: MyApp.Notifications.Notification,
      extensions: [AshTypescript.Resource]

    # Optional: TypeScript type generation
    typescript do
      type_name("DeliveryReceipt")
    end

    # Add your User relationship
    relationships do
      belongs_to :user, MyApp.Accounts.User do
        source_attribute :user_id
        destination_attribute :id
        allow_nil? true
        public? true
      end
    end

    # Optional: Custom policies
    # policies do
    #   policy action_type(:read) do
    #     authorize_if expr(user_id == ^actor(:id))
    #   end
    # end
  end
  ```

  ## State Machine

  Tracks delivery lifecycle:
  - `:pending` → Initial state when receipt is created
  - `:scheduled` → Oban job has been enqueued
  - `:sending` → Actively being delivered
  - `:sent` → Successfully delivered
  - `:failed` → Delivery failed (temporary, can retry)
  - `:failed_permanent` → Delivery failed permanently (no retry)
  - `:skipped` → Delivery was intentionally skipped

  ## Content Storage

  All message content (subject, body, embeds, etc.) is stored in the receipt at creation time.
  This enables debugging, retry without re-rendering, and historical audit trails.

  ## Configuration

  Configure your custom resource in your app:

  ```elixir
  config :ash_dispatch,
    delivery_receipt_resource: MyApp.Deliveries.DeliveryReceipt
  ```

  See `AshDispatch.Resources.DeliveryReceipt.Base` for full documentation.
  """

  # Minimal struct definition for internal type references.
  # Consuming apps should create their own resource using the Base module.
  defstruct [
    :id,
    :event_id,
    :transport,
    :user_id,
    :notification_id,
    :audience,
    :status,
    :recipient,
    :provider_id,
    :provider_response,
    :subject,
    :body_text,
    :body_html,
    :content,
    :oban_job_id,
    :error_message,
    :retry_count,
    :last_retry_at,
    :sent_at,
    :delivered_at,
    :source_type,
    :source_id
  ]
end
