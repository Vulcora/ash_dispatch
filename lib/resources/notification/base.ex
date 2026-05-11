defmodule AshDispatch.Resources.Notification.Base do
  @moduledoc """
  Provides the base DSL for Notification resources.

  This module exports a `__using__` macro that consuming apps can use to create
  their own Notification resource with a user relationship.

  ## Usage

      defmodule MyApp.Notifications.Notification do
        use AshDispatch.Resources.Notification.Base,
          repo: MyApp.Repo,
          domain: MyApp.Notifications,
          extensions: [AshTypescript.Resource]

        # Optional: TypeScript type configuration
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

  ## Options

  - `:repo` - (required) Ecto repo module
  - `:domain` - (required) Ash domain
  - `:extensions` - Additional Ash extensions (e.g., `[AshTypescript.Resource]`)
  - `:table` - Postgres table name. Defaults to `"notifications"`. Override
    when the consumer app already owns that table for a legacy notification
    system and ash_dispatch needs to coexist (e.g., `table: "dispatch_notifications"`).
  """

  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)
    domain = Keyword.fetch!(opts, :domain)
    extra_extensions = Keyword.get(opts, :extensions, [])
    table = Keyword.get(opts, :table, "notifications")
    # AshDispatch.Resource provides counter broadcasting DSL
    all_extensions = [AshDispatch.Resource] ++ extra_extensions

    quote do
      use Ash.Resource,
        domain: unquote(domain),
        data_layer: AshPostgres.DataLayer,
        extensions: unquote(all_extensions)

      require Ash.Query
      require Ash.Expr

      postgres do
        table unquote(table)
        repo(unquote(repo))

        identity_wheres_to_sql(unique_idempotency_key: "idempotency_key IS NOT NULL")
      end

      actions do
        defaults [:read, :destroy]

        read :get do
          description "Get a notification by ID"
          get_by :id
        end

        create :create do
          primary? true

          accept [
            :user_id,
            :type,
            :title,
            :message,
            :metadata,
            :action_label,
            :action_url,
            :source,
            :occurred_at,
            :event_id,
            :idempotency_key
          ]

          change fn changeset, _ ->
            metadata = Ash.Changeset.get_attribute(changeset, :metadata) || %{}

            occurred_at =
              Ash.Changeset.get_attribute(changeset, :occurred_at) || DateTime.utc_now()

            changeset
            |> Ash.Changeset.change_attribute(:metadata, metadata)
            |> Ash.Changeset.change_attribute(:occurred_at, occurred_at)
          end
        end

        update :update do
          primary? true
          accept [:read, :read_at]
        end

        read :list_for_user do
          argument :user_id, :uuid do
            allow_nil? false
          end

          filter expr(^ref(:user_id) == ^arg(:user_id))
          prepare build(sort: [inserted_at: :desc])
        end

        update :mark_as_read do
          accept []
          require_atomic? false

          change set_attribute(:read, true)
          change set_attribute(:read_at, &DateTime.utc_now/0)
        end

        action :mark_all_as_read, :map do
          description "Mark all notifications as read for a user"

          argument :user_id, :uuid do
            allow_nil? false
          end

          run fn input, _context ->
            require Ash.Query
            arg_user_id = input.arguments.user_id

            result =
              __MODULE__
              |> Ash.Query.new()
              |> Ash.Query.filter(^ref(:user_id) == ^arg_user_id and ^ref(:read) == false)
              |> Ash.bulk_update(:mark_as_read, %{},
                authorize?: false,
                return_errors?: true,
                # Use stream strategy to ensure changes are triggered
                strategy: :stream
              )

            case result do
              %Ash.BulkResult{status: :success, error_count: 0} ->
                # records_count is only available when return_records?: true
                # With stream strategy, we don't get a count, so just return success
                {:ok, %{success: true}}

              %Ash.BulkResult{errors: errors} when errors != [] ->
                {:error, Ash.Error.to_error_class(errors)}

              _ ->
                {:ok, %{success: true}}
            end
          end
        end
      end

      # Counter broadcasting for unread notifications
      counters do
        counter :unread_notifications,
          trigger_on: [:create, :mark_as_read, :mark_all_as_read],
          query_filter: [read: false],
          audience: :user,
          invalidates: ["notifications"]
      end

      attributes do
        uuid_v7_primary_key :id

        attribute :user_id, :uuid do
          public? true
          allow_nil? false
          description "User this notification is for"
        end

        attribute :type, :atom do
          public? true
          allow_nil? false
          default :info
          constraints one_of: [:info, :success, :warning, :error]
          description "Visual type of notification for UI styling"
        end

        attribute :title, :string do
          public? true
          allow_nil? false
          description "Short notification title"
        end

        attribute :message, :string do
          public? true
          allow_nil? false
          description "Full notification message"
        end

        attribute :metadata, :map do
          public? true
          allow_nil? false
          default %{}
          description "Additional metadata for the notification"
        end

        attribute :action_label, :string do
          public? true
          allow_nil? true
          description "Label for action button (e.g., 'View Order')"
        end

        attribute :action_url, :string do
          public? true
          allow_nil? true
          description "Optional URL to navigate to when clicking notification"
        end

        attribute :source, :string do
          public? true
          allow_nil? true
          description "Optional source identifier for the notification"
        end

        attribute :occurred_at, :utc_datetime_usec do
          public? true
          allow_nil? false
          default {DateTime, :utc_now, []}
          description "When the event that triggered this notification occurred"
        end

        attribute :read, :boolean do
          public? true
          allow_nil? false
          default false
          description "Whether the user has read this notification"
        end

        attribute :read_at, :utc_datetime_usec do
          public? true
          allow_nil? true
          description "When the notification was read"
        end

        attribute :event_id, :string do
          public? true
          allow_nil? true
          description "Event that triggered this notification (e.g., 'orders.created')"
        end

        attribute :idempotency_key, :string do
          public? true
          allow_nil? true
          description "Optional key to prevent duplicate notifications"
        end

        timestamps(public?: true)
      end

      identities do
        identity :unique_idempotency_key, [:idempotency_key],
          where: expr(not is_nil(^ref(:idempotency_key)))
      end

      code_interface do
        define :create
        define :get
        define :mark_as_read
        define :mark_all_as_read, args: [:user_id]
        define :list_for_user, args: [:user_id]
        define :read, action: :read
      end
    end
  end
end
