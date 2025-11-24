defmodule AshDispatch.Resources.DeliveryReceipt do
  @moduledoc """
  Unified delivery tracking for all transports (email, in-app, Discord, SMS, etc).

  This resource tracks the complete lifecycle of message delivery with a state machine:
  - :pending → Initial state when receipt is created
  - :scheduled → Oban job has been enqueued
  - :sending → Actively being delivered
  - :sent → Successfully delivered
  - :failed → Delivery failed (temporary, can retry)
  - :failed_permanent → Delivery failed permanently (no retry)
  - :skipped → Delivery was intentionally skipped

  ## Content Storage

  All message content (subject, body, embeds, etc.) is stored in the receipt at creation time.
  This enables:
  - Debugging of what was actually sent
  - Retry without re-rendering
  - Historical audit trail

  ## Retry Pattern

  Failed deliveries (status: :failed) can be retried by:
  1. Checking retry_count < max_retries
  2. Re-enqueueing Oban job with receipt_id
  3. Updating status to :scheduled
  4. Incrementing retry_count

  A cron job (`RetryFailedDeliveries`) handles automatic retries.

  ## Transport-Specific Fields

  - For :email: subject, body_html, body_text
  - For :in_app: notification_id links to Notification
  - For :discord: embeds stored in content map
  - All: content map for flexible storage

  ## Configuration

  The resource requires configuration for:
  - `repo`: Postgres repository module
  - `user_resource`: User resource module for relationships

  Example:

      config :ash_dispatch,
        repo: MyApp.Repo,
        user_resource: MyApp.Accounts.User
  """

  use Ash.Resource,
    domain: AshDispatch.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [
      AshStateMachine,
      AshTypescript.Resource,
      AshDispatch.Extensions.AddUserRelationship
    ]

  postgres do
    table "delivery_receipts"
    repo(Application.compile_env(:ash_dispatch, :repo, nil))

    references do
      reference(:notification, on_delete: :nilify)
      # No user reference - user_id is just a UUID attribute
      # The consuming app can add a foreign key constraint in their migration if needed
    end
  end

  state_machine do
    initial_states([:pending])
    default_initial_state(:pending)
    state_attribute(:status)
    extra_states([:sending, :sent, :failed_permanent, :skipped, :scheduled, :failed])

    transitions do
      # Initial creation → scheduled when Oban job enqueued
      transition(:schedule, from: :pending, to: :scheduled)

      # Scheduled → sending when worker starts (can also transition from pending if job runs immediately)
      transition(:mark_sending, from: [:scheduled, :pending], to: :sending)

      # Sending → sent/failed based on delivery result
      transition(:mark_sent, from: [:sending, :scheduled, :pending], to: :sent)
      transition(:mark_failed, from: [:sending, :scheduled, :pending], to: :failed)

      transition(:mark_failed_permanent,
        from: [:sending, :scheduled, :failed],
        to: :failed_permanent
      )

      # Skip delivery (e.g., user preferences)
      transition(:skip, from: [:pending, :scheduled, :sending], to: :skipped)

      # Retry failed deliveries
      transition(:retry, from: :failed, to: :scheduled)
    end
  end

  typescript do
    type_name("DeliveryReceipt")
  end

  actions do
    defaults [:read, :destroy]

    read :get do
      get_by :id
      prepare build(load: [:notification])
      prepare {AshDispatch.Preparations.LoadObanJob, []}
    end

    read :get_by_provider_id do
      description "Find delivery receipt by provider ID (for webhook lookups)"
      get_by :provider_id
      prepare build(load: [:notification])
    end

    read :list_for_user do
      argument :user_id, :uuid, allow_nil?: false
      argument :status, :atom, allow_nil?: true
      argument :transport, :atom, allow_nil?: true
      argument :event_id, :string, allow_nil?: true

      filter expr(user_id == ^arg(:user_id))
      filter expr(if(is_nil(^arg(:status)), true, status == ^arg(:status)))
      filter expr(if(is_nil(^arg(:transport)), true, transport == ^arg(:transport)))
      filter expr(if(is_nil(^arg(:event_id)), true, event_id == ^arg(:event_id)))

      pagination offset?: true, keyset?: true, default_limit: 20
      prepare build(sort: [inserted_at: :desc])
    end

    read :list_all do
      description "List all delivery receipts with filters (admin only)"

      argument :status, :atom, allow_nil?: true
      argument :transport, :atom, allow_nil?: true
      argument :event_id, :string, allow_nil?: true
      argument :audience, :atom, allow_nil?: true

      filter expr(if(is_nil(^arg(:status)), true, status == ^arg(:status)))
      filter expr(if(is_nil(^arg(:transport)), true, transport == ^arg(:transport)))
      filter expr(if(is_nil(^arg(:event_id)), true, event_id == ^arg(:event_id)))
      filter expr(if(is_nil(^arg(:audience)), true, audience == ^arg(:audience)))

      pagination offset?: true, keyset?: true, default_limit: 50
      prepare build(sort: [inserted_at: :desc])
      prepare {AshDispatch.Preparations.LoadObanJob, []}
    end

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
        :notification_id,
        :user_id
      ]

      change fn changeset, _ ->
        content = Ash.Changeset.get_attribute(changeset, :content) || %{}
        Ash.Changeset.change_attribute(changeset, :content, content)
      end
    end

    update :update do
      primary? true

      accept [
        :oban_job_id,
        :provider_response,
        :error_message,
        :retry_count,
        :last_retry_at,
        :notification_id
      ]
    end

    update :schedule do
      accept [:oban_job_id, :notification_id]
      change transition_state(:scheduled)
    end

    update :mark_sending do
      accept []
      change transition_state(:sending)
    end

    update :mark_sent do
      require_atomic? false
      accept [:provider_id, :provider_response, :notification_id]
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
      accept [:oban_job_id]

      validate {AshDispatch.Validations.ValidateCanRetry, []}
      change transition_state(:scheduled)

      change fn changeset, _ ->
        retry_count = Ash.Changeset.get_attribute(changeset, :retry_count) || 0

        changeset
        |> Ash.Changeset.change_attribute(:retry_count, retry_count + 1)
        |> Ash.Changeset.change_attribute(:last_retry_at, DateTime.utc_now())
      end
    end

    update :record_webhook_event do
      description "Record email event from provider webhook (delivery lifecycle and engagement)"

      accept [
        :sent_at,
        :delivered_at,
        :delivery_delayed_at,
        :failed_at,
        :opened_at,
        :clicked_at,
        :bounced_at,
        :complained_at,
        :provider_response
      ]
    end
  end

  policies do
    # Bypass all policies for create/update/destroy (for workers, tests)
    bypass action_type([:create, :update, :destroy]) do
      authorize_if always()
    end

    # Read policies - only admins with configured permission can read
    # Configure permission checker: config :ash_dispatch, permission_checker: MyApp.PolicyHelpers.HasPermission
    policy action_type(:read) do
      authorize_if {AshDispatch.PolicyChecks.HasPermission, permission: :manage_delivery_receipts}

      forbid_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    # Event identification
    attribute :event_id, :string do
      public? true
      allow_nil? false
      description "Event type identifier (e.g., 'requests.new_reseller_request')"
    end

    # Transport and routing
    attribute :transport, :atom do
      public? true
      allow_nil? false
      constraints one_of: [:email, :in_app, :discord, :sms, :slack]
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

    # Content storage (for emails primarily)
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
      description "Transport-specific content (embeds, attachments, etc.)"
    end

    # Delivery tracking
    attribute :oban_job_id, :integer do
      public? true
      allow_nil? true
      description "Linked Oban job ID for async delivery"
    end

    attribute :notification_id, :uuid do
      public? true
      allow_nil? true
      description "For in-app transport: links to Notification"
    end

    attribute :user_id, :uuid do
      public? true
      allow_nil? true

      description """
      User this receipt is for (required for :in_app and :email, optional for :discord/:slack/:webhook).
      Per-recipient design: one receipt per user for user-based transports.
      """
    end

    # Provider response and debugging
    attribute :provider_id, :string do
      public? true
      allow_nil? true
      description "Provider-specific message ID (e.g., Resend email ID)"
    end

    attribute :provider_response, :map do
      public? true
      default %{}
      description "Response from delivery provider (Resend, Discord API, etc.)"
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

    # Email delivery lifecycle tracking (from webhooks)
    attribute :sent_at, :utc_datetime_usec do
      public? true
      allow_nil? true
      description "Timestamp when email was accepted by Resend (from webhook)"
    end

    attribute :delivered_at, :utc_datetime_usec do
      public? true
      allow_nil? true
      description "Timestamp when email was delivered to recipient's inbox (from webhook)"
    end

    attribute :delivery_delayed_at, :utc_datetime_usec do
      public? true
      allow_nil? true
      description "Timestamp when email delivery was delayed (from webhook)"
    end

    attribute :failed_at, :utc_datetime_usec do
      public? true
      allow_nil? true
      description "Timestamp when email delivery failed (from webhook)"
    end

    # Email engagement tracking (from webhooks)
    attribute :opened_at, :utc_datetime_usec do
      public? true
      allow_nil? true
      description "Timestamp when email was opened (from webhook)"
    end

    attribute :clicked_at, :utc_datetime_usec do
      public? true
      allow_nil? true
      description "Timestamp when email link was clicked (from webhook)"
    end

    attribute :bounced_at, :utc_datetime_usec do
      public? true
      allow_nil? true
      description "Timestamp when email bounced (from webhook)"
    end

    attribute :complained_at, :utc_datetime_usec do
      public? true
      allow_nil? true
      description "Timestamp when email was marked as spam (from webhook)"
    end

    timestamps(public?: true)
  end

  relationships do
    belongs_to :notification, AshDispatch.Resources.Notification do
      source_attribute :notification_id
      destination_attribute :id
      allow_nil? true
      public? true
    end
  end

  calculations do
    # Loaded Oban job data (not persisted to database)
    calculate :oban_job, :map, {AshDispatch.Calculations.ObanJob, []} do
      public? true
      description "Loaded Oban job data (queried from Oban jobs table)"
    end

    # User relationship via calculation (avoids compile-time cross-project dependency)
    # Configured via: config :ash_dispatch, user_resource: MyApp.Accounts.User, user_domain: MyApp.Accounts
    # NOTE: AshTypescript can't load nested fields on calculations - frontend should load user as a whole field
    calculate :user, :struct, {AshDispatch.Calculations.LoadUser, []} do
      public? true
      description "Associated user (loaded from configured user_resource)"
      # Allow nil since not all receipts have a user_id
      allow_nil? true
    end
  end
end
