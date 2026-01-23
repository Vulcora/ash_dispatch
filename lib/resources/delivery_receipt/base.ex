defmodule AshDispatch.Resources.DeliveryReceipt.Base do
  @moduledoc """
  Provides the base DSL for DeliveryReceipt resources.

  This module exports a `__using__` macro that consuming apps can use to create
  their own DeliveryReceipt resource with a user relationship, similar to how
  ash_paper_trail creates version resources.

  ## Usage

      defmodule MyApp.Deliveries.DeliveryReceipt do
        use AshDispatch.Resources.DeliveryReceipt.Base,
          repo: MyApp.Repo,
          domain: MyApp.Deliveries,
          notification_resource: MyApp.Notifications.Notification,
          extensions: [AshTypescript.Resource]

        # Optional: TypeScript type configuration
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
      end

  ## Options

  - `:repo` - (required) Ecto repo module
  - `:domain` - (required) Ash domain for the resource
  - `:notification_resource` - (required) Your Notification resource module
  - `:user_resource` - User resource module for auto-created relationship (optional)
  - `:extensions` - Additional Ash extensions (e.g., `[AshTypescript.Resource]`)
  """

  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)
    domain = Keyword.fetch!(opts, :domain)
    notification_resource = Keyword.fetch!(opts, :notification_resource)
    user_resource = Keyword.get(opts, :user_resource)
    extra_extensions = Keyword.get(opts, :extensions, [])
    all_extensions = [AshStateMachine] ++ extra_extensions

    quote do
      use Ash.Resource,
        domain: unquote(domain),
        data_layer: AshPostgres.DataLayer,
        authorizers: [Ash.Policy.Authorizer],
        extensions: unquote(all_extensions)

      postgres do
        table "delivery_receipts"
        repo(unquote(repo))

        references do
          reference(:notification, on_delete: :nilify)

          # Add user reference if user_resource is configured
          if unquote(user_resource) do
            reference(:user, on_delete: :nilify)
          end
        end
      end

      state_machine do
        initial_states([:pending])
        default_initial_state(:pending)
        state_attribute(:status)
        extra_states([:sending, :sent, :failed_permanent, :skipped, :scheduled, :failed])

        transitions do
          transition(:schedule, from: :pending, to: :scheduled)
          transition(:mark_sending, from: [:scheduled, :pending], to: :sending)
          transition(:mark_sent, from: [:sending, :scheduled, :pending], to: :sent)
          transition(:mark_failed, from: [:sending, :scheduled, :pending], to: :failed)

          transition(:mark_failed_permanent,
            from: [:sending, :scheduled, :failed],
            to: :failed_permanent
          )

          transition(:skip, from: [:pending, :scheduled, :sending], to: :skipped)
          transition(:retry, from: :failed, to: :scheduled)
        end
      end

      # Relationships
      relationships do
        belongs_to :notification, unquote(notification_resource) do
          source_attribute :notification_id
          destination_attribute :id
          allow_nil? true
          public? true
          define_attribute? false
        end

        # Add user relationship if user_resource is configured
        if unquote(user_resource) do
          belongs_to :user, unquote(user_resource) do
            source_attribute :user_id
            destination_attribute :id
            allow_nil? true
            public? true
            define_attribute? false
          end
        end
      end

      # All attributes
      attributes do
        uuid_primary_key :id

        attribute :event_id, :string, allow_nil?: false, public?: true

        attribute :transport, :atom,
          allow_nil?: false,
          public?: true,
          constraints: [one_of: [:email, :in_app, :discord, :sms, :webhook, :slack]]

        attribute :user_id, :uuid, allow_nil?: true, public?: true
        attribute :notification_id, :uuid, allow_nil?: true, public?: true

        attribute :audience, :atom,
          allow_nil?: false,
          public?: true,
          description: "Target audience type (flexible - apps can use any atom)"

        attribute :status, :atom,
          default: :pending,
          allow_nil?: false,
          public?: true,
          constraints: [
            one_of: [:pending, :scheduled, :sending, :sent, :failed, :failed_permanent, :skipped]
          ]

        attribute :recipient, :string, allow_nil?: false, public?: true

        attribute :provider_id, :string,
          allow_nil?: true,
          public?: true,
          description: "Provider-specific message ID"

        attribute :provider_response, :map,
          default: %{},
          allow_nil?: false,
          public?: true,
          description: "Response from delivery provider"

        attribute :subject, :string, allow_nil?: true, public?: true
        attribute :body_text, :string, allow_nil?: true, public?: true
        attribute :body_html, :string, allow_nil?: true, public?: true
        attribute :content, :map, default: %{}, allow_nil?: false, public?: true
        attribute :oban_job_id, :integer, allow_nil?: true, public?: true
        attribute :error_message, :string, allow_nil?: true, public?: true
        attribute :retry_count, :integer, default: 0, allow_nil?: false, public?: true

        attribute :last_retry_at, :utc_datetime_usec,
          allow_nil?: true,
          public?: true,
          description: "Timestamp of last retry attempt"

        attribute :sent_at, :utc_datetime_usec, allow_nil?: true, public?: true

        attribute :delivered_at, :utc_datetime_usec,
          allow_nil?: true,
          public?: true,
          description: "When provider confirmed delivery"

        attribute :delivery_delayed_at, :utc_datetime_usec,
          allow_nil?: true,
          public?: true,
          description: "When delivery was delayed by provider"

        attribute :failed_at, :utc_datetime_usec,
          allow_nil?: true,
          public?: true,
          description: "When delivery failed"

        attribute :opened_at, :utc_datetime_usec,
          allow_nil?: true,
          public?: true,
          description: "When email was opened"

        attribute :clicked_at, :utc_datetime_usec,
          allow_nil?: true,
          public?: true,
          description: "When link was clicked"

        attribute :bounced_at, :utc_datetime_usec,
          allow_nil?: true,
          public?: true,
          description: "When email bounced"

        attribute :complained_at, :utc_datetime_usec,
          allow_nil?: true,
          public?: true,
          description: "When spam complaint received"

        # Source resource linking (for navigation back to the source)
        attribute :source_type, :string,
          allow_nil?: true,
          public?: true,
          description: "Source resource module name"

        attribute :source_id, :uuid,
          allow_nil?: true,
          public?: true,
          description: "Source resource ID"

        attribute :locale, :string,
          allow_nil?: true,
          public?: true,
          description: "Locale used for template rendering (e.g., 'en', 'sv')"

        timestamps(public?: true)
      end

      calculations do
        calculate :oban_job, :map, {AshDispatch.Calculations.ObanJob, []} do
          public? true
          description "Loaded Oban job data"
        end

        calculate :source_url, :string, {AshDispatch.Calculations.SourceUrl, []} do
          public? true
          description "URL path to the source resource (computed from event module)"
          allow_nil? true
        end

        calculate :source_label, :string, {AshDispatch.Calculations.SourceLabel, []} do
          public? true
          description "Human-readable label for the source resource type"
          allow_nil? true
        end

        calculate :admin_url, :string, {AshDispatch.Calculations.AdminUrl, []} do
          public? true
          description "Admin-specific URL path to the source resource"
          allow_nil? true
        end

        calculate :from_email, :string do
          public? true
          description "Sender email address extracted from content"
          allow_nil? true

          calculation fn records, _context ->
            Enum.map(records, fn record ->
              case record.content do
                %{"from" => %{"email" => email}} when is_binary(email) -> email
                %{"from" => email} when is_binary(email) -> email
                _ -> nil
              end
            end)
          end
        end

        calculate :from_name, :string do
          public? true
          description "Sender name extracted from content"
          allow_nil? true

          calculation fn records, _context ->
            Enum.map(records, fn record ->
              case record.content do
                %{"from" => %{"name" => name}} when is_binary(name) -> name
                _ -> nil
              end
            end)
          end
        end
      end

      actions do
        default_accept :*
        defaults [:read, :destroy]

        create :create do
          accept [
            :event_id,
            :transport,
            :user_id,
            :notification_id,
            :audience,
            :recipient,
            :subject,
            :body_text,
            :body_html,
            :content,
            :oban_job_id,
            :provider_id,
            :provider_response,
            :source_type,
            :source_id,
            :locale
          ]
        end

        read :list_all do
          description "List all delivery receipts with filters (admin only)"

          argument :status, :atom, allow_nil?: true
          argument :transport, :atom, allow_nil?: true
          argument :event_id, :string, allow_nil?: true
          argument :audience, :atom, allow_nil?: true

          filter expr(if(is_nil(^arg(:status)), true, ^ref(:status) == ^arg(:status)))
          filter expr(if(is_nil(^arg(:transport)), true, ^ref(:transport) == ^arg(:transport)))
          filter expr(if(is_nil(^arg(:event_id)), true, ^ref(:event_id) == ^arg(:event_id)))
          filter expr(if(is_nil(^arg(:audience)), true, ^ref(:audience) == ^arg(:audience)))

          pagination offset?: true, keyset?: true, default_limit: 50
          prepare build(sort: [inserted_at: :desc])
          prepare {AshDispatch.Preparations.LoadObanJob, []}
        end

        read :list_for_user do
          argument :user_id, :uuid, allow_nil?: false
          argument :status, :atom, allow_nil?: true
          argument :transport, :atom, allow_nil?: true
          argument :event_id, :string, allow_nil?: true

          filter expr(^ref(:user_id) == ^arg(:user_id))
          filter expr(if(is_nil(^arg(:status)), true, ^ref(:status) == ^arg(:status)))
          filter expr(if(is_nil(^arg(:transport)), true, ^ref(:transport) == ^arg(:transport)))
          filter expr(if(is_nil(^arg(:event_id)), true, ^ref(:event_id) == ^arg(:event_id)))

          pagination offset?: true, keyset?: true, default_limit: 20
          prepare build(sort: [inserted_at: :desc])
        end

        read :get do
          argument :id, :uuid, allow_nil?: false
          get? true
          filter expr(^ref(:id) == ^arg(:id))
          prepare build(load: [:notification])
          prepare {AshDispatch.Preparations.LoadObanJob, []}
        end

        read :get_by_provider_id do
          description "Find delivery receipt by provider ID (for webhook lookups)"
          argument :provider_id, :string, allow_nil?: false
          get? true
          filter expr(^ref(:provider_id) == ^arg(:provider_id))
          prepare build(load: [:notification])
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
          change transition_state(:sending)
        end

        update :mark_sent do
          require_atomic? false
          accept [:provider_id, :provider_response, :notification_id, :oban_job_id]
          change transition_state(:sent)

          change fn changeset, _ ->
            changeset
            |> Ash.Changeset.change_attribute(:sent_at, DateTime.utc_now())
            |> Ash.Changeset.change_attribute(:error_message, nil)
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

          # Enqueue a new Oban job to process this retry
          change {AshDispatch.Changes.EnqueueRetryJob, []}
        end

        update :send_now do
          description "Manually trigger sending for a scheduled delivery (creates new Oban job)"
          require_atomic? false

          # Check configured authorizer (if any)
          validate fn _changeset, context ->
            actor = context.actor
            authorizer = AshDispatch.Config.send_now_authorizer()

            cond do
              # No actor (system/worker call) - always allow
              is_nil(actor) ->
                :ok

              # No authorizer configured - allow any authenticated actor
              is_nil(authorizer) ->
                :ok

              # Call configured authorizer
              true ->
                case authorizer.authorize(actor) do
                  :ok -> :ok
                  {:error, message} -> {:error, field: :base, message: message}
                end
            end
          end

          # Only allow from scheduled state (or pending if stuck)
          validate fn changeset, _context ->
            status = Ash.Changeset.get_attribute(changeset, :status)

            if status in [:scheduled, :pending] do
              :ok
            else
              {:error,
               field: :status,
               message: "Can only send now from scheduled or pending state, current: #{status}"}
            end
          end

          # Enqueue a new Oban job immediately
          change {AshDispatch.Changes.EnqueueRetryJob, []}
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
          authorize_if {AshDispatch.PolicyChecks.HasPermission,
                        permission: :manage_delivery_receipts}

          forbid_if always()
        end
      end

      identities do
        identity :oban_job, [:oban_job_id]
      end
    end
  end
end
