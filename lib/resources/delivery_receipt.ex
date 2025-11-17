defmodule AshDispatch.Resources.DeliveryReceipt do
  @moduledoc """
  Tracks the delivery lifecycle of events across all transports.

  This resource follows a receipt-first pattern:
  1. Receipt created with full content (status: `:pending`)
  2. Transport delivers the message
  3. Status updated based on result (`:sent`, `:failed`, `:scheduled`, etc.)

  ## State Machine

  States:
  - `:pending` → Initial state when receipt is created
  - `:scheduled` → Oban job enqueued for async delivery
  - `:sending` → Actively being delivered
  - `:sent` → Successfully delivered
  - `:failed` → Delivery failed (can retry)
  - `:failed_permanent` → Delivery failed permanently (no retry)
  - `:skipped` → Intentionally skipped (e.g., user opted out)

  ## Content Storage

  All message content is stored in the receipt at creation time:
  - Email: `subject`, `body_html`, `body_text`
  - In-app: `content` map with title, message, action_url
  - Other transports: `content` map with transport-specific data

  This enables:
  - Full audit trail of what was sent
  - Retry without re-rendering templates
  - Debugging delivery issues

  ## Usage

  Receipts are created automatically by the dispatcher. You can query them:

      AshDispatch.Resources.DeliveryReceipt
      |> Ash.Query.filter(event_id == "orders.created")
      |> Ash.Query.filter(status == :sent)
      |> Ash.read!()

  """

  use Ash.Resource,
    domain: AshDispatch.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshStateMachine]

  state_machine do
    initial_states [:pending]
    default_initial_state :pending
    state_attribute :status

    transitions do
      # Initial creation → scheduled when async job enqueued
      transition :schedule, from: :pending, to: :scheduled

      # Scheduled → sending when delivery starts
      # Also allow pending → sending for synchronous deliveries
      transition :mark_sending, from: [:scheduled, :pending], to: :sending

      # Sending → sent/failed based on result
      transition :mark_sent, from: [:sending, :scheduled, :pending], to: :sent
      transition :mark_failed, from: [:sending, :scheduled, :pending], to: :failed

      transition :mark_failed_permanent,
        from: [:sending, :scheduled, :failed],
        to: :failed_permanent

      # Skip delivery (e.g., user preferences)
      transition :skip, from: [:pending, :scheduled, :sending], to: :skipped

      # Retry failed deliveries
      transition :retry, from: :failed, to: :scheduled
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :event_id,
        :transport,
        :audience,
        :recipient,
        :subject,
        :body_html,
        :body_text,
        :content,
        :scheduled_for
      ]

      change fn changeset, _ ->
        # Ensure content is a map
        content = Ash.Changeset.get_attribute(changeset, :content) || %{}
        Ash.Changeset.change_attribute(changeset, :content, content)
      end
    end

    update :update do
      primary? true

      accept [
        :provider_id,
        :provider_response,
        :error_message,
        :retry_count,
        :last_retry_at
      ]
    end

    update :schedule do
      accept []
      change transition_state(:scheduled)
    end

    update :mark_sending do
      accept []
      change transition_state(:sending)
    end

    update :mark_sent do
      require_atomic? false
      accept [:provider_id, :provider_response]
      change transition_state(:sent)

      change fn changeset, _ ->
        Ash.Changeset.change_attribute(changeset, :sent_at, DateTime.utc_now())
      end
    end

    update :mark_failed do
      require_atomic? false
      accept [:error_message, :provider_response]
      change transition_state(:failed)

      change fn changeset, _ ->
        retry_count = Ash.Changeset.get_attribute(changeset, :retry_count) || 0

        changeset
        |> Ash.Changeset.change_attribute(:retry_count, retry_count + 1)
        |> Ash.Changeset.change_attribute(:last_retry_at, DateTime.utc_now())
      end
    end

    update :mark_failed_permanent do
      accept [:error_message, :provider_response]
      change transition_state(:failed_permanent)
    end

    update :skip do
      accept [:error_message]
      change transition_state(:skipped)
    end

    update :retry do
      require_atomic? false
      accept []
      change transition_state(:scheduled)

      change fn changeset, _ ->
        retry_count = Ash.Changeset.get_attribute(changeset, :retry_count) || 0

        changeset
        |> Ash.Changeset.change_attribute(:retry_count, retry_count + 1)
        |> Ash.Changeset.change_attribute(:last_retry_at, DateTime.utc_now())
      end
    end
  end

  attributes do
    uuid_primary_key :id

    # Event identification
    attribute :event_id, :string do
      public? true
      allow_nil? false
      description "Event type identifier (e.g., 'orders.created')"
    end

    # Transport and routing
    attribute :transport, :atom do
      public? true
      allow_nil? false
      constraints one_of: [:email, :in_app, :discord, :slack, :sms, :webhook]
      description "Delivery transport/channel"
    end

    attribute :audience, :atom do
      public? true
      allow_nil? false
      constraints one_of: [:user, :admin, :system]
      description "Target audience type"
    end

    attribute :recipient, :string do
      public? true
      allow_nil? false
      description "Recipient identifier (email, user_id, etc.)"
    end

    # State machine
    attribute :status, :atom do
      public? true
      allow_nil? false
      default :pending

      constraints one_of: [
                    :pending,
                    :scheduled,
                    :sending,
                    :sent,
                    :failed,
                    :failed_permanent,
                    :skipped
                  ]

      description "Delivery lifecycle state"
    end

    # Content storage
    attribute :subject, :string do
      public? true
      allow_nil? true
      description "Email subject line"
    end

    attribute :body_html, :string do
      public? true
      allow_nil? true
      description "HTML email body"
    end

    attribute :body_text, :string do
      public? true
      allow_nil? true
      description "Plain text email body"
    end

    # Flexible content storage for any transport
    attribute :content, :map do
      public? true
      default %{}
      description "Transport-specific content (embeds, notifications, etc.)"
    end

    # Provider response and debugging
    attribute :provider_id, :string do
      public? true
      allow_nil? true
      description "Provider-specific message ID"
    end

    attribute :provider_response, :map do
      public? true
      default %{}
      description "Response from delivery provider"
    end

    attribute :error_message, :string do
      public? true
      allow_nil? true
      description "Error message if delivery failed"
    end

    # Retry tracking
    attribute :retry_count, :integer do
      public? true
      default 0
      description "Number of retry attempts"
    end

    attribute :last_retry_at, :utc_datetime_usec do
      public? true
      allow_nil? true
      description "Timestamp of last retry attempt"
    end

    # Scheduling
    attribute :scheduled_for, :utc_datetime_usec do
      public? true
      allow_nil? true
      description "When the message should be sent (for delayed delivery)"
    end

    attribute :sent_at, :utc_datetime_usec do
      public? true
      allow_nil? true
      description "Timestamp when message was successfully sent"
    end

    timestamps(public?: true)
  end
end
