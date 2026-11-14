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
  - `:data_layer` - defaults to `AshPostgres.DataLayer`. `Ash.DataLayer.Ets`
    works for tests; the `postgres` block is then left out.
  - `:table` - Postgres table name. Defaults to `"notifications"`. Override
    when the consumer app already owns that table for a legacy notification
    system and ash_dispatch needs to coexist (e.g., `table: "dispatch_notifications"`).
  - `:multitenancy` - `:context` puts notifications in one schema per tenant
    (since 0.9.4). Absent, the resource declares no multitenancy and nothing in
    the library ever mentions a tenant to it. The `tenant` ATTRIBUTE below is a
    different thing and is always there: it says which tenant a notification
    belongs to, in one table. See the Tenancy guide.
  - `:primary_key` - `:uuid_v7` (the default, unchanged) or `:uuid`. The v7
    key's migration default is `uuid_generate_v7()`, which your database must
    have; `:uuid` uses `gen_random_uuid()`, which is built in. See
    `AshDispatch.Resources.PrimaryKey` and the Tenancy guide (since 0.9.4-rc.2).
  """

  @doc false
  # The body of `mark_all_as_read` / `mark_all_as_seen`: every one of the
  # user's notifications matching `pending` through `action`, in one bulk
  # update — the user is the `user_id` argument, or the actor. The actor is
  # carried into the bulk update, so the changes and notifiers see who did it.
  def mark_all(resource, action, input, context, pending, after_fun) do
    require Ash.Query

    user_id =
      input.arguments[:user_id] ||
        case context.actor do
          %{id: id} -> id
          _ -> nil
        end

    tenant = input.arguments[:tenant]

    if is_nil(user_id) do
      {:error,
       Ash.Error.Invalid.exception(
         errors: [ArgumentError.exception("no user: pass user_id or an actor")]
       )}
    else
      query =
        resource
        |> Ash.Query.new()
        |> Ash.Query.filter(^Ash.Expr.ref(:user_id) == ^user_id)
        |> then(fn query ->
          Enum.reduce(pending, query, fn
            {field, nil}, query -> Ash.Query.filter(query, is_nil(^Ash.Expr.ref(field)))
            {field, value}, query -> Ash.Query.filter(query, ^Ash.Expr.ref(field) == ^value)
          end)
        end)
        # The SCHEMA this runs in, when this resource is per tenant. Set on the
        # query, not only on the bulk update: `Ash.bulk_update/4` validates the
        # query it is given, and a query without a tenant is refused before the
        # options are read.
        |> AshDispatch.Tenancy.set_query(context.tenant)
        |> then(fn query ->
          # A notification without a tenant (every row from before 0.9.0, and
          # every dispatch without `:tenant`) belongs to the person, and is
          # in each tenant's inbox — as `:unread` counts it.
          if tenant,
            do:
              Ash.Query.filter(
                query,
                is_nil(^Ash.Expr.ref(:tenant)) or ^Ash.Expr.ref(:tenant) == ^tenant
              ),
            else: query
        end)

      result =
        Ash.bulk_update(
          query,
          action,
          %{},
          [
            actor: context.actor,
            authorize?: false,
            context: %{ash_dispatch_bulk: true},
            return_errors?: true,
            # Use stream strategy to ensure changes are triggered
            strategy: :stream
          ] ++ AshDispatch.Tenancy.opts(__MODULE__, context.tenant)
        )

      case result do
        %Ash.BulkResult{errors: errors} when is_list(errors) and errors != [] ->
          {:error, Ash.Error.to_error_class(errors)}

        _ ->
          after_fun.(user_id)
          {:ok, %{success: true}}
      end
    end
  end

  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)
    domain = Keyword.fetch!(opts, :domain)
    extra_extensions = Keyword.get(opts, :extensions, [])

    # Consumers could always add extensions but never notifiers, which is an
    # arbitrary asymmetry: a notifier is how you observe what a resource did
    # without touching how it does it. Without this, an app that wants to
    # react to receipt transitions has to reach for a change instead — and a
    # non-atomic change forces `require_atomic? false` onto every update
    # action in this base, which the consumer cannot edit.
    extra_notifiers = Keyword.get(opts, :notifiers, [])
    table = Keyword.get(opts, :table, "notifications")
    data_layer = Keyword.get(opts, :data_layer, AshPostgres.DataLayer)
    postgres? = Macro.expand(data_layer, __CALLER__) == AshPostgres.DataLayer

    postgres_block =
      if postgres? do
        quote do
          postgres do
            table unquote(table)
            repo(unquote(repo))

            identity_wheres_to_sql(unique_idempotency_key: "idempotency_key IS NOT NULL")
          end
        end
      end

    # AshDispatch.Resource provides counter broadcasting DSL
    all_extensions = [AshDispatch.Resource] ++ extra_extensions

    # 0.9.4. Absent, the resource declares no multitenancy and the DSL below
    # is what 0.9.3 generated; the `tenant` COLUMN has been here since 0.9.0
    # either way, and the two are different things.
    multitenancy_block = AshDispatch.Tenancy.Base.block(Keyword.get(opts, :multitenancy))

    # 0.9.4-rc.2; see `AshDispatch.Resources.PrimaryKey`. Absent, `:uuid_v7`,
    # which is what every release since 0.9.0 has emitted here.
    primary_key =
      AshDispatch.Resources.PrimaryKey.attribute(:uuid_v7, Keyword.get(opts, :primary_key))

    quote do
      # The authorizer MUST be present: without one, `authorize?: true` is a
      # no-op and every read returns the whole table. Notifications are
      # per-user data, so the practical result is that any signed-in user can
      # read every other user's notification feed.
      #
      # Compare `DeliveryReceipt.Base`, which has always had an authorizer —
      # the inconsistency lived here in the library, not in consumer apps.
      #
      # The policies live below in the same module rather than in the
      # consumer — an authorizer without policies would make the resource
      # default-deny for every app that doesn't happen to define its own.
      use Ash.Resource,
        domain: unquote(domain),
        data_layer: unquote(data_layer),
        authorizers: [Ash.Policy.Authorizer],
        extensions: unquote(all_extensions),
        notifiers: unquote(extra_notifiers)

      require Ash.Query
      require Ash.Expr

      @doc false
      # What this library declared on this resource, as opposed to what the
      # host declared. Read by `AshDispatch.Resources.Base` and, through it,
      # by `sdk: :if_events` — which must not count the unread counter below
      # as a reason to generate a TypeScript client (#50).
      def __ash_dispatch_base_content__, do: %{counters: [:unread_notifications]}

      unquote(multitenancy_block)
      unquote(postgres_block)

      policies do
        # Notifications are per-user. NOTE on ordering: these policies
        # compile BEFORE any the consumer app declares (the `use` line
        # precedes the consumer's own blocks), non-bypass policies are AND-ed
        # in order, and a later consumer `bypass` cannot re-open an earlier
        # forbid. Consumers can therefore RESTRICT further, but never loosen
        # — which is exactly the guarantee per-user data wants.
        policy action_type(:read) do
          authorize_if expr(^ref(:user_id) == ^actor(:id))
        end

        # Updates (`:mark_as_read` and the primary `:update`, which only
        # accepts read/read_at): your own notifications only. This must NOT
        # be a blanket `forbid_if always()` on update — `:mark_as_read` is an
        # update action, and two ANDed policies where one always forbids
        # would make marking your own notification as read impossible.
        policy action_type(:update) do
          authorize_if expr(^ref(:user_id) == ^actor(:id))
        end

        # `mark_all_as_read` / `mark_all_as_seen` take an optional user_id
        # ARGUMENT and run bulk_update with authorize?: false internally —
        # without this check anyone could mark another user's entire feed as
        # read. Without the argument they work on the actor's own feed.
        policy action([:mark_all_as_read, :mark_all_as_seen]) do
          authorize_if expr(^arg(:user_id) == ^actor(:id))
          authorize_if expr(is_nil(^arg(:user_id)) and not is_nil(^actor(:id)))
        end

        # Counts the actor's own notifications, through the read policy above.
        policy action(:unread_count) do
          authorize_if actor_present()
        end

        # Notifications are created by the dispatcher, which runs with
        # authorize?: false. No path in from the outside.
        policy action_type([:create, :destroy]) do
          forbid_if always()
        end
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
            :idempotency_key,
            :category,
            :tenant
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

        # The actor's unread, not archived notifications — what a bell counts.
        read :unread do
          argument :tenant, :string, allow_nil?: true

          filter expr(
                   ^ref(:user_id) == ^actor(:id) and ^ref(:read) == false and
                     is_nil(^ref(:archived_at))
                 )

          # A notification without a tenant is counted in every tenant.
          filter expr(
                   is_nil(^arg(:tenant)) or is_nil(^ref(:tenant)) or
                     ^ref(:tenant) == ^arg(:tenant)
                 )

          prepare build(sort: [inserted_at: :desc])
        end

        action :unread_count, :integer do
          description "How many unread notifications the actor has"
          argument :tenant, :string, allow_nil?: true

          run fn input, context ->
            # The action's own tenant, when this resource is per tenant: a
            # count must not reach across schemas, and `:tenant` as an ARGUMENT
            # is the column filter, which is a different question.
            opts = [actor: context.actor] ++ AshDispatch.Tenancy.opts(__MODULE__, context.tenant)

            __MODULE__
            |> Ash.Query.for_read(:unread, %{tenant: input.arguments[:tenant]}, opts)
            |> Ash.count(opts)
          end
        end

        update :mark_as_seen do
          accept []
          require_atomic? false
          change set_attribute(:seen_at, &DateTime.utc_now/0)
        end

        update :archive do
          accept []
          require_atomic? false
          change set_attribute(:archived_at, &DateTime.utc_now/0)
        end

        update :unarchive do
          accept []
          require_atomic? false
          change set_attribute(:archived_at, nil)
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

          change fn changeset, _context ->
            if is_nil(changeset.data.seen_at) do
              Ash.Changeset.change_attribute(changeset, :seen_at, DateTime.utc_now())
            else
              changeset
            end
          end

          change after_action(fn changeset, record, _context ->
                   if not Map.get(changeset.context, :ash_dispatch_bulk, false) do
                     AshDispatch.Helpers.NotificationLoader.broadcast_read(record.user_id)
                   end

                   {:ok, record}
                 end)
        end

        action :mark_all_as_read, :map do
          description "Mark all of a user's notifications as read (the actor's, without user_id)"

          argument :user_id, :uuid do
            allow_nil? true
          end

          argument :tenant, :string, allow_nil?: true

          run fn input, context ->
            AshDispatch.Resources.Notification.Base.mark_all(
              __MODULE__,
              :mark_as_read,
              input,
              context,
              [read: false],
              &AshDispatch.Helpers.NotificationLoader.broadcast_read/1
            )
          end
        end

        action :mark_all_as_seen, :map do
          description "Mark all of a user's notifications as seen (the actor's, without user_id)"

          argument :user_id, :uuid do
            allow_nil? true
          end

          argument :tenant, :string, allow_nil?: true

          run fn input, context ->
            AshDispatch.Resources.Notification.Base.mark_all(
              __MODULE__,
              :mark_as_seen,
              input,
              context,
              [seen_at: nil],
              fn _user_id -> :ok end
            )
          end
        end
      end

      # Counter broadcasting for unread notifications
      counters do
        counter :unread_notifications,
          trigger_on: [:create, :mark_as_read, :mark_all_as_read, :archive, :unarchive],
          # The same set `:unread` counts: an archived notification is not unread.
          query_filter: [read: false, archived_at: nil],
          audience: :user,
          invalidates: ["notifications"]
      end

      attributes do
        unquote(primary_key)

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

        attribute :category, :string do
          public? true
          allow_nil? true
          description "The event's category (metadata `category:`), for filtering a feed"
        end

        attribute :tenant, :string do
          public? true
          allow_nil? true
          description "Tenant the event happened in (`AshDispatch.Context.tenant_key/1`)"
        end

        attribute :seen_at, :utc_datetime_usec do
          public? true
          allow_nil? true
          description "When the user first saw the notification (opened the list)"
        end

        attribute :archived_at, :utc_datetime_usec do
          public? true
          allow_nil? true
          description "When the user archived the notification; archived ones are not unread"
        end

        timestamps(public?: true)
      end

      identities do
        identity :unique_idempotency_key, [:idempotency_key],
          where: expr(not is_nil(^ref(:idempotency_key))),
          pre_check?: unquote(not postgres?)
      end

      code_interface do
        define :create
        define :get
        define :mark_as_read
        define :mark_as_seen
        define :archive
        define :unarchive
        define :mark_all_as_read, args: [:user_id]
        define :mark_all_as_seen
        define :unread
        define :unread_count
        define :list_for_user, args: [:user_id]
        define :read, action: :read
      end
    end
  end
end
