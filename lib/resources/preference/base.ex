defmodule AshDispatch.Resources.Preference.Base do
  @moduledoc """
  The base DSL for a notification preference resource: who wants which
  event on which transport.

  Each row says *on* or *off* for one scope:

  | column      | meaning                                                      |
  |-------------|--------------------------------------------------------------|
  | `tenant`    | the tenant the row belongs to (`nil` in an app without tenancy) |
  | `user_id`   | the person, or `nil` for the tenant's default                |
  | `event_id`  | one event, e.g. `"meetings.invited"` — or                    |
  | `category`  | every event of a category, e.g. `"reminders"`                |
  | `transport` | `:email`, `:in_app`, …                                       |
  | `enabled`   | the answer                                                   |

  Exactly one of `event_id` and `category` is set. The answer for a
  recipient is the most specific row that exists, in this order:

  1. the person's row for the event
  2. the person's row for the event's category
  3. the tenant's row for the event
  4. the tenant's row for the category
  5. the event's own default (`metadata: [preference_default: ...]`, else on)

  The person beats the tenant, the tenant beats the event. An event with
  `metadata: [user_configurable: false]` is mandatory and never consults
  this table at all.

  `AshDispatch.UserPreference.Resource` is the checker that reads it.

  ## Usage

      defmodule MyApp.Notifications.Preference do
        use AshDispatch.Resources.Preference.Base,
          repo: MyApp.Repo,
          domain: MyApp.Notifications
      end

      # config/config.exs
      config :ash_dispatch,
        user_preference: AshDispatch.UserPreference.Resource,
        preference_resource: MyApp.Notifications.Preference

  Then generate the migration (`mix ash.codegen add_notification_preferences`).
  The scope identity is `NULLS NOT DISTINCT`, which needs Postgres 15 or
  later.

  ## Options

  - `:repo` - (required) Ecto repo module
  - `:domain` - (required) Ash domain
  - `:table` - Postgres table name. Defaults to `"notification_preferences"`
  - `:extensions` - additional Ash extensions
  - `:notifiers` - additional Ash notifiers
  - `:policies?` - include the library's policies (default `true`), see below
  - `:data_layer` - defaults to `AshPostgres.DataLayer`; `Ash.DataLayer.Ets`
    works for tests (the `postgres` block is then left out)
  - `:multitenancy` - `:context` puts preference rows in one schema per tenant
    (since 0.9.4). The `tenant` column keeps working either way — for a
    per-tenant resource it is a redundant copy of what the schema says, and the
    library writes and filters both. See the Tenancy guide
  - `:primary_key` - `:uuid_v7` (the default, unchanged) or `:uuid`. The v7
    key's migration default is `uuid_generate_v7()`, which your database must
    have; `:uuid` uses `gen_random_uuid()`, which is built in. See
    `AshDispatch.Resources.PrimaryKey` and the Tenancy guide (since 0.9.4-rc.2)

  ## Policies

  With `policies?: true` (the default):

  - **read**: your own rows, and every tenant default (`user_id` nil) — a
    settings screen shows the default next to the person's choice
  - **create / update / destroy**: your own rows. A tenant default can be
    written by an actor that passes `AshDispatch.PolicyChecks.HasPermission`
    with `permission: :manage_notification_preferences` (the app's
    `:permission_checker`), or with `authorize?: false` after the app has
    checked who is asking.

  As with the notification resource, a consumer's own policies can only
  restrict further. To write all of them yourself, pass `policies?: false`.

  ## Actions

  - `:read`, `:destroy` (defaults)
  - `:set` — create that upserts on the scope: `%{tenant, user_id,
    event_id | category, transport, enabled}`
  - `:for_scope` — the rows of one tenant for one event (by id or
    category), for the given user ids plus the tenant's defaults. What the
    checker runs, once per dispatch
  """

  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)
    domain = Keyword.fetch!(opts, :domain)
    table = Keyword.get(opts, :table, "notification_preferences")
    extra_extensions = Keyword.get(opts, :extensions, [])
    extra_notifiers = Keyword.get(opts, :notifiers, [])
    policies? = Keyword.get(opts, :policies?, true)
    data_layer = Keyword.get(opts, :data_layer, AshPostgres.DataLayer)
    postgres? = Macro.expand(data_layer, __CALLER__) == AshPostgres.DataLayer

    authorizers = if policies?, do: [Ash.Policy.Authorizer], else: []

    # 0.9.4; see `AshDispatch.Tenancy.Base`. Absent, nothing is emitted.
    multitenancy_block = AshDispatch.Tenancy.Base.block(Keyword.get(opts, :multitenancy))

    # 0.9.4-rc.2; see `AshDispatch.Resources.PrimaryKey`. Absent, `:uuid_v7`,
    # which is what every release since 0.9.0 has emitted here.
    primary_key =
      AshDispatch.Resources.PrimaryKey.attribute(:uuid_v7, Keyword.get(opts, :primary_key))

    postgres_block =
      if postgres? do
        quote do
          postgres do
            table unquote(table)
            repo(unquote(repo))
          end
        end
      end

    policies_block =
      if policies? do
        quote do
          policies do
            policy action_type(:read) do
              authorize_if expr(^ref(:user_id) == ^actor(:id))
              authorize_if expr(is_nil(^ref(:user_id)))
            end

            policy action_type([:create, :update, :destroy]) do
              authorize_if AshDispatch.PolicyChecks.PreferenceWriter
            end
          end
        end
      end

    quote do
      use Ash.Resource,
        domain: unquote(domain),
        data_layer: unquote(data_layer),
        authorizers: unquote(authorizers),
        extensions: unquote(extra_extensions),
        notifiers: unquote(extra_notifiers)

      require Ash.Query
      require Ash.Expr

      unquote(multitenancy_block)
      unquote(postgres_block)
      unquote(policies_block)

      attributes do
        unquote(primary_key)

        attribute :tenant, :string do
          public? true
          allow_nil? true
          description "Tenant the row belongs to; nil in an app without tenancy"
        end

        attribute :user_id, :uuid do
          public? true
          allow_nil? true
          description "The person; nil for the tenant's default"
        end

        attribute :event_id, :string do
          public? true
          allow_nil? true
          description "One event (exactly one of event_id and category is set)"
        end

        attribute :category, :string do
          public? true
          allow_nil? true
          description "Every event of a category (exactly one of event_id and category is set)"
        end

        attribute :transport, :atom do
          public? true
          allow_nil? false
          description "Transport the row applies to, e.g. :email or :in_app"
        end

        attribute :enabled, :boolean do
          public? true
          allow_nil? false
          description "Whether deliveries in this scope are wanted"
        end

        timestamps(public?: true)
      end

      identities do
        identity :unique_scope, [:tenant, :user_id, :event_id, :category, :transport],
          nils_distinct?: false,
          pre_check?: unquote(not postgres?)
      end

      validations do
        validate fn changeset, _context ->
          event_id = Ash.Changeset.get_attribute(changeset, :event_id)
          category = Ash.Changeset.get_attribute(changeset, :category)

          if is_nil(event_id) == is_nil(category) do
            {:error, field: :event_id, message: "set exactly one of event_id and category"}
          else
            :ok
          end
        end
      end

      actions do
        defaults [:read, :destroy]

        create :set do
          primary? true
          accept [:tenant, :user_id, :event_id, :category, :transport, :enabled]
          upsert? true
          upsert_identity :unique_scope
          upsert_fields [:enabled, :updated_at]
        end

        update :update do
          primary? true
          accept [:enabled]
          require_atomic? false
        end

        read :for_scope do
          argument :tenant, :string, allow_nil?: true
          argument :event_id, :string, allow_nil?: true
          argument :category, :string, allow_nil?: true
          argument :user_ids, {:array, :uuid}, allow_nil?: false, default: []

          filter expr(
                   (is_nil(^arg(:tenant)) and is_nil(^ref(:tenant))) or
                     ^ref(:tenant) == ^arg(:tenant)
                 )

          filter expr(
                   (not is_nil(^arg(:event_id)) and ^ref(:event_id) == ^arg(:event_id)) or
                     (not is_nil(^arg(:category)) and ^ref(:category) == ^arg(:category))
                 )

          filter expr(is_nil(^ref(:user_id)) or ^ref(:user_id) in ^arg(:user_ids))
        end
      end

      code_interface do
        define :set
        define :for_scope, args: [:tenant, :event_id, :category, :user_ids]
      end
    end
  end
end
