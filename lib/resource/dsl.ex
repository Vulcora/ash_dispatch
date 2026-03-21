defmodule AshDispatch.Resource.Dsl do
  @moduledoc """
  DSL sections for AshDispatch.Resource extension.
  """

  alias Spark.Dsl.{Entity, Section}

  @doc """
  The main `dispatch` section for defining events in resources.
  """
  def dispatch_section do
    %Section{
      name: :dispatch,
      describe: """
      Define events that are dispatched when resource actions occur.

      Events can be simple (inline DSL) or complex (with callback modules).

      ## Locale Configuration

      Configure locales at resource level (inherited by all events):

          dispatch do
            locales ["sv", "en", "no"]
            locale_from :visitor_locale  # Field on resource to extract locale

            event :created, trigger_on: :create do
              channels [
                [transport: :email, audience: :customer, locale_from: :visitor_locale],
                [transport: :email, audience: :admin, locale: "sv"]
              ]
            end
          end

      Locale priority (highest to lowest):
      1. Channel-level `locale` (static) or `locale_from` (dynamic)
      2. Event-level `locales` / `locale_from`
      3. Resource-level `locales` / `locale_from`
      4. Config default_locale

      ## Audience Path Configuration

      For child resources that access users through parent relationships,
      use `audience_prefix` to automatically prepend paths:

          dispatch do
            audience_prefix :order  # All audiences go through :order first

            event :created, trigger_on: :create do
              channels do
                channel :email, audience: :user  # Resolves to [:order, :user]
              end
            end
          end

      For explicit overrides, use the `audience` entity:

          dispatch do
            audience :assigned_seller, [:order, :assigned_seller]

            event :assigned, trigger_on: :assign do
              channels do
                channel :email, audience: :assigned_seller
              end
            end
          end
      """,
      entities: [event_entity(), entity_changes_entity(), resource_meta_entity(), audience_prefix_entity(), audience_entity(), locales_entity()],
      sections: []
    }
  end

  @doc """
  The `event` entity for defining individual events.
  """
  def event_entity do
    %Entity{
      name: :event,
      describe: """
      Define an event that is dispatched when actions occur.

      ## Hybrid Architecture

      AshDispatch uses a **hybrid approach**:
      - DSL configuration takes precedence
      - Generated modules provide fallbacks (templates, callbacks)

      ### Basic Usage

      Define events directly in DSL, then run `mix ash.codegen` to generate
      event modules and templates:

          event :created,
            trigger_on: :create,
            channels: [
              [transport: :in_app, audience: :user],
              [transport: :email, audience: :user, delay: 300]
            ],
            content: [
              subject: "Order #\{\{order_number\}\} created",
              notification_title: "Your order was created",
              notification_message: "Order #\{\{order_number\}\} is being processed"
            ],
            metadata: [notification_type: :success]

          # After `mix ash.codegen`:
          # - Event module: lib/app/domain/events/created/event.ex
          # - Templates: lib/app/domain/events/created/templates/

      ### Custom Module Override

      For complex events, provide your own module:

          event :escalated,
            trigger_on: :escalate,
            module: MyApp.Events.Orders.Escalated

      When `module:` is set, the generator skips this event and your module
      handles all callbacks (recipients, channels, templates, etc.).
      """,
      args: [:name],
      target: AshDispatch.Resource.Dsl.Event,
      schema: [
        name: [
          type: :atom,
          required: true,
          doc: "Name of the event (e.g., :created, :updated, :cancelled)"
        ],
        trigger_on: [
          type: {:or, [:atom, {:list, :atom}]},
          required: true,
          doc: """
          Action name(s) that trigger this event, or `:manual` for manual-only events.

          Can be a single action, list of actions, or the special value `:manual`.

          ## Manual-Only Events

          Use `trigger_on: :manual` for events that are dispatched programmatically
          via `AshDispatch.Dispatcher.dispatch/3` rather than automatically on actions.

          This is useful for:
          - Events triggered by external systems (AshAuthentication senders)
          - Events that need custom context not available in action changes
          - Events that should only be triggered manually from admin UI

          Manual events are still registered in the EventRegistry for:
          - Preview in admin email template UI
          - Manual trigger functionality
          - TypeScript type generation

          Example:

              # Dispatched by AshAuthentication sender, not auto-triggered
              event :password_reset,
                trigger_on: :manual,
                event_id: "accounts.password_reset",
                data_key: :user,
                channels: [[transport: :email, audience: :user]]
          """
        ],
        module: [
          type: :atom,
          required: false,
          doc: """
          Custom callback module that implements AshDispatch.Event behaviour.

          When set, this module acts as an **override** - the generator will NOT
          create a module for this event, and your module will be used instead.

          Use this for complex events that need custom logic:
          - Custom recipient resolution
          - Conditional sending based on runtime data
          - Complex template preparation
          - Multi-step workflows

          For simple events, leave this unset:
          - `:in_app`, `:webhook`, `:discord`, `:slack` transports work entirely from DSL
          - `:email` and `:sms` require templates, which are generated by `mix ash.codegen`
          """
        ],
        event_id: [
          type: :string,
          required: false,
          doc: """
          Explicit event ID. If not specified, auto-generated as
          "{resource_name}.{event_name}" (e.g., "product_order.created").
          """
        ],
        load: [
          type: {:list, :any},
          default: [],
          doc: """
          Relationships to preload before dispatching the event.
          Supports nested loads like `[:user, product_order_items: :product]`.
          """
        ],
        domain: [
          type: :atom,
          required: false,
          doc: "Event domain (e.g., :orders, :tickets). Defaults to resource domain."
        ],
        data_key: [
          type: :atom,
          required: false,
          doc: """
          Key to use for resource data in context (e.g., :order, :ticket, :reseller_request).
          If not specified, defaults to the resource's table name.
          This is useful when event modules expect specific data keys.
          """
        ],
        include_actor_as: [
          type: :atom,
          required: false,
          doc: """
          Alias key for the actor in context.data.

          The actor (user who triggered the action) is always included in `context.data`
          as `:actor`. Use this option to also include it under a semantic alias.

          Example:

              event :invited,
                trigger_on: :invite,
                data_key: :invited_user,
                include_actor_as: :invited_by,
                channels: [[transport: :email, audience: :user]]

          This makes the actor available as both:
          - `context.data.actor` (always)
          - `context.data.invited_by` (alias)

          Useful for clearer template access when the actor has a specific role
          in the event (inviter, approver, assignee, etc.).
          """
        ],
        template_path: [
          type: :string,
          required: false,
          doc: """
          Optional path to template directory (relative to project root).

          If not provided, derives from event_id automatically:
          - Event ID: "requests.new_reseller_request"
          - Convention: "lib/{otp_app}/{domain}/templates/{event_name}"
          - Result: "lib/magasin/requests/templates/new_reseller_request"

          This only applies when using file-based templates (development).
          Module-based events use their own __DIR__ for templates.

          Override this for custom template locations:

              event :urgent_alert,
                template_path: "lib/my_app/custom/templates/alerts"
          """
        ],
        channels: [
          type: {:list, {:or, [:keyword_list, :map]}},
          default: [],
          doc: """
          List of delivery channels for this event. Each channel is a keyword list or map.

          ## Channel Configuration

          **Required fields:**
          - `transport`: :email | :in_app | :discord | :sms | :slack | :webhook
          - `audience`: :user | :admin | custom atom

          **Optional fields:**
          - `delay`: Delay in seconds before sending (default: 0)
          - `policy`: :always | :skip_if_read (default: :always)
          - `variant`: Custom variant for template selection (e.g., "admin" for email.admin.html.heex)
          - `locale`: Static locale for this channel (e.g., "sv" for internal emails)
          - `locale_from`: Field on record to extract locale (e.g., :visitor_locale)
          - `locales`: List of locales for template generation (e.g., ["sv", "en"])
          - `webhook_url`: For webhook transport
          - `content`: Transport-specific content (see below)
          - `metadata`: Transport-specific metadata (see below)
          - `deduplicate_group`: Atom for grouping channels for deduplication (see below)
          - `optional`: Suppress warnings when no recipients found (default: false)

          ## Deduplication with deduplicate_group

          Channels sharing the same `deduplicate_group` are deduplicated - if a user
          matches multiple audiences in the same group, they receive only ONE notification.
          First matching channel (by DSL order) wins.

          This is useful when audiences overlap (e.g., :admin and :stakeholders both
          contain some users) but you only want each user notified once.

              channels: [
                # These two share a group - user in both gets only one in_app notification
                [transport: :in_app, audience: :stakeholders, deduplicate_group: :internal],
                [transport: :in_app, audience: :admin, deduplicate_group: :internal],

                # These share a different group - deduplication applies within this group
                [transport: :email, audience: :admin, deduplicate_group: :admin_emails],
                [transport: :email, audience: :finance, deduplicate_group: :admin_emails],

                # No group = no deduplication - customer always gets notification
                [transport: :in_app, audience: :customer]
              ]

          Note: Channels without `deduplicate_group` are never deduplicated.

          ## Optional Channels

          Use `optional: true` when it's expected that an audience may have no recipients.
          This suppresses warnings that would otherwise be logged.

          This is useful for:
          - Dynamic audiences that may not exist yet (e.g., :lead_owner before assignment)
          - Conditional audiences based on workflow state
          - MFA-based audiences that return empty lists in certain scenarios

              channels: [
                # Primary notification - always has a recipient
                [transport: :in_app, audience: :user],

                # Optional - lead owner may not be assigned yet
                [transport: :in_app, audience: :lead_owner, optional: true],
                [transport: :email, audience: :lead_owner, optional: true]
              ]

          When `optional: true`, no warning is logged if:
          - The MFA resolver function returns an empty list (no recipients found)
          - The MFA resolver function doesn't exist
          - No recipient configuration is found for the audience

          ## Transport-Specific Content & Metadata

          You can nest `content` and `metadata` under each channel for transport-specific configuration:

              channels: [
                [
                  transport: :in_app,
                  audience: :admin,
                  content: [
                    title: "New request received",
                    message: "From \{\{company_name\}\}",
                    action_url: "/admin/requests/\{\{id\}\}"
                  ],
                  metadata: [
                    notification_type: :info,
                    action_required: true
                  ]
                ],
                [
                  transport: :email,
                  audience: :admin,
                  content: [
                    subject: "New reseller request from \{\{company_name\}\}",
                    from_email: "system@example.com"
                  ]
                ]
              ]

          Alternatively, use event-level `content` and `metadata` for shared configuration.
          Channel-level configuration takes precedence over event-level.

          ## Content Keys Per Transport

          **:email transport:**
          - `subject`: Email subject line (supports \{\{variable\}\} interpolation)
          - `from_email`: From address (optional, defaults to app config)

          **:in_app transport:**
          - `title`: Notification title
          - `message`: Notification message body
          - `action_url`: Optional action button URL

          **:discord / :slack transport:**
          - `message`: Message text

          **:in_app metadata:**
          - `notification_type`: :info | :success | :warning | :error
          - `action_required`: boolean
          """
        ],
        content: [
          type: {:or, [:keyword_list, :map]},
          default: [],
          doc: """
          Content configuration as keyword list or map. Common keys:
          - subject: Email subject (supports \{\{variable\}\} syntax)
          - notification_title: In-app notification title
          - notification_message: In-app notification message
          - action_url: Action URL for notifications
          """
        ],
        metadata: [
          type: {:or, [:keyword_list, :map]},
          default: [],
          doc: """
          Event metadata as keyword list or map. Common keys:
          - notification_type: :info | :success | :warning | :error
          - action_required: boolean
          - user_configurable: boolean
          """
        ],
        recipient: [
          type: {:or, [:keyword_list, :map]},
          default: [],
          doc: """
          Recipient field extraction configuration (event-level override).

          Configure how to extract identifiers and names from recipient structs
          for specific transports. This overrides application-level config.

          Format (nested by transport):

              recipient: [
                email: [
                  identifier: :primary_email,
                  name: :full_name
                ],
                sms: [
                  identifier: :mobile_phone
                ]
              ]

          Field specifications support:
          - `:field_name` - Direct field access
          - `{:field, [:nested, :path]}` - Nested path
          - `{:string_field, "key"}` - String key
          - `&Module.function/1` - Custom function

          See AshDispatch.Event.RecipientExtractor for full documentation.
          """
        ],
        recipient_filter: [
          type: {:or, [:keyword_list, :map]},
          default: [],
          doc: """
          Recipient filter configuration (event-level override).

          Configure which recipients to query for each audience. This overrides
          application-level config (`:ash_dispatch, :recipient_filters`).

          Format (nested by audiences):

              recipient_filter: [
                audiences: [
                  admin: [admin: true, on_duty: true],
                  user: [status: :active],
                  support: [role: :support, available: true]
                ]
              ]

          Filters use Ash Query filter syntax. Empty list means no filter (all users).

          Application-level defaults are configured in config.exs:

              config :ash_dispatch,
                recipient_filters: [
                  audiences: [
                    admin: [admin: true],
                    user: []
                  ]
                ]

          When a channel has `audience: :admin`, the system:
          1. Checks event-level `recipient_filter[:audiences][:admin]` (if set)
          2. Falls back to config `recipient_filters[:audiences][:admin]`
          3. Applies filter to User resource query

          See AshDispatch.Event.Helpers.resolve_recipients_for_audience for details.
          """
        ],
        manual_trigger_filter: [
          type: :any,
          required: false,
          doc: """
          Ash filter expression to control visibility in manual trigger UI.

          Filters are applied to the target user (recipient) to determine if this
          event should be shown as an option in manual trigger interfaces.

          ## Examples

              # Only show if user hasn't confirmed email
              manual_trigger_filter: [confirmed_at: nil]

              # Only show if user is archived
              manual_trigger_filter: [archived_at: [not: nil]]

              # Complex filter with multiple conditions
              manual_trigger_filter: [admin: true, archived: false]

          Defaults to no filter (show for all users).
          """
        ],
        should_send_filter: [
          type: :any,
          required: false,
          doc: """
          Ash filter expression to control whether auto-triggered events should send.

          Filters are applied to the target user (recipient) to determine if this
          auto-triggered event should actually be sent to them.

          ## Examples

              # Only send if user hasn't confirmed email yet
              should_send_filter: [confirmed_at: nil]

              # Only send to active, non-archived users
              should_send_filter: [archived_at: nil, active: true]

          Defaults to no filter (always send).

          Note: This filter is only checked for auto-triggered events. Manual
          triggers always send (assuming applicable_for_user? returns true).
          """
        ],
        invalidates: [
          type: {:list, :string},
          default: [],
          doc: """
          Frontend query keys to invalidate when this event is dispatched.

          When notifications are broadcast to recipients, the frontend can use these
          keys to invalidate TanStack Query caches, triggering automatic refetches.

          ## Example

              event :created,
                trigger_on: :create,
                invalidates: ["partner_leads", "partner_stats"],
                channels: [[transport: :in_app, audience: :partner_owner]]

          The invalidation keys are broadcast along with the notification, allowing
          the frontend to react to data changes in real-time without polling.

          Common patterns:
          - Resource lists: `["leads", "projects", "invoices"]`
          - Dashboard stats: `["partner_stats", "admin_stats"]`
          - Related data: `["customer_orders", "customer_invoices"]`
          """
        ],
        locales: [
          type: {:list, :string},
          default: [],
          doc: """
          Locales for template generation at the event level.

          When specified, the template generator will create locale-specific template
          variants for each locale. Overrides resource-level locales.

          ## Example

              event :created,
                trigger_on: :create,
                locales: ["sv", "en", "no"],
                channels: [[transport: :email, audience: :customer]]

          This generates:
          - email.html.heex (default/fallback)
          - email.sv.html.heex
          - email.en.html.heex
          - email.no.html.heex
          """
        ],
        locale_from: [
          type: :atom,
          required: false,
          doc: """
          Field on the resource to extract the runtime locale from.

          At dispatch time, this field is read from the record to determine
          which locale-specific template to render. Overrides resource-level locale_from.

          ## Example

              event :created,
                trigger_on: :create,
                locale_from: :visitor_locale,
                channels: [[transport: :email, audience: :customer]]

          If the lead has `visitor_locale: "en"`, the English template is rendered.
          Falls back to default template if locale-specific template doesn't exist.
          """
        ]
      ]
    }
  end

  @doc """
  The `entity_changes` entity for enabling real-time entity change broadcasting.

  When enabled, CRUD events for this resource are automatically broadcast
  as `entity_change` and `entity_created` channel events, enabling real-time
  UI updates like entity snapshots, toast notifications, and status dots.
  """
  def entity_changes_entity do
    %Entity{
      name: :entity_changes,
      describe: """
      Enable automatic broadcasting of entity CRUD events via the user channel.

      When enabled, the TypeScript SDK generates an entity store that tracks
      live entity snapshots, and the socket provider auto-wires `entity_change`
      events into the store.

      ## Example

          dispatch do
            entity_changes true
          end

      Or with options:

          dispatch do
            entity_changes true,
              trigger_on: [:create, :update, :complete, :activate],
              label_fields: [:title],
              status_field: :status
          end

      The generator introspects the resource to auto-detect:
      - Label fields (first of :title, :name that exists as an attribute)
      - Status field (from AshStateMachine state_attribute if present)
      - States (from AshStateMachine initial_states + transition targets)
      """,
      args: [:enabled],
      target: AshDispatch.Resource.Dsl.EntityChanges,
      schema: [
        enabled: [
          type: :boolean,
          required: true,
          doc: "Whether to enable entity change broadcasting for this resource."
        ],
        trigger_on: [
          type: {:list, :atom},
          required: false,
          doc: """
          Optional list of action names to restrict broadcasting to.
          If not specified, broadcasts on all create, update, and destroy actions.
          """
        ],
        label_fields: [
          type: {:list, :atom},
          default: [:title, :name],
          doc: """
          Fields to use for the entity label in snapshots.
          The first field with a non-nil value is used.
          Defaults to `[:title, :name]`.
          """
        ],
        status_field: [
          type: :atom,
          required: false,
          doc: """
          Field to use for entity status in snapshots.
          Auto-detected from AshStateMachine state_attribute if present.
          """
        ]
      ]
    }
  end

  @doc """
  The `resource_meta` entity for TypeScript resource metadata generation.

  Provides metadata about the resource that the TypeScript SDK uses to generate
  navigation paths, labels, and type-safe resource constants.
  """
  def resource_meta_entity do
    %Entity{
      name: :resource_meta,
      describe: """
      Define resource metadata for TypeScript generation.

      The generator uses this to emit a `RESOURCES` constant with labels,
      plural forms, navigation paths, and state machine states.

      ## Example

          dispatch do
            resource_meta label: "Task", plural: "tasks", nav_path: "/tasks"
          end

      Most values are auto-derived if not specified:
      - `label`: From the resource module name (e.g., `Mosis.Tasks.Task` → "Task")
      - `plural`: From the postgres table name (e.g., "tasks")
      - `nav_path`: From plural (e.g., "/tasks")
      - States: Auto-introspected from AshStateMachine if present
      """,
      target: AshDispatch.Resource.Dsl.ResourceMeta,
      schema: [
        label: [
          type: :string,
          required: false,
          doc: "Human-readable singular label (e.g., \"Task\"). Auto-derived from resource name."
        ],
        plural: [
          type: :string,
          required: false,
          doc: "Plural form (e.g., \"tasks\"). Auto-derived from postgres table name."
        ],
        nav_path: [
          type: :string,
          required: false,
          doc: "Navigation base path (e.g., \"/tasks\"). Auto-derived from plural."
        ]
      ]
    }
  end

  @doc """
  The `audience_prefix` entity for child resources.

  Specifies a relationship prefix that all relationship-based audiences
  should go through before resolving. This is useful for child resources
  like OrderItem that access users through their parent Order.
  """
  def audience_prefix_entity do
    %Entity{
      name: :audience_prefix,
      describe: """
      Set a relationship prefix for all audiences in this resource.

      When a child resource accesses users through a parent relationship,
      this prefix is automatically prepended to relationship-based audiences.

      ## Example

          dispatch do
            audience_prefix :order

            event :created, trigger_on: :create do
              channels do
                channel :email, audience: :user  # Resolves to [:order, :user]
              end
            end
          end

      The transformer will automatically derive the nested load structure:
      `[:order, :user]` becomes `[order: :user]` in the load option.

      Note: Broadcast audiences (like `:admin`) are not affected by the prefix
      since they query the User resource directly rather than following relationships.
      """,
      args: [:prefix],
      target: AshDispatch.Resource.Dsl.AudiencePrefix,
      schema: [
        prefix: [
          type: :atom,
          required: true,
          doc: "Relationship name to prefix all relationship-based audiences with"
        ]
      ]
    }
  end

  @doc """
  The `audience` entity for explicit audience path overrides.

  Allows defining custom paths for specific audiences, useful when an audience
  needs a different path than the default or when combined with audience_prefix.
  """
  def audience_entity do
    %Entity{
      name: :audience,
      describe: """
      Define an explicit relationship path for an audience.

      Use this to override the default path for a specific audience,
      or to define custom audiences with relationship chains.

      ## Example

          dispatch do
            audience :assigned_seller, [:order, :assigned_seller]
            audience :created_by, [:order, :created_by]

            event :assigned, trigger_on: :assign do
              channels do
                channel :email, audience: :assigned_seller
              end
            end
          end

      The transformer will derive nested loads from these paths:
      `[:order, :assigned_seller]` becomes `[order: :assigned_seller]`.
      """,
      args: [:name, :path],
      target: AshDispatch.Resource.Dsl.AudienceOverride,
      schema: [
        name: [
          type: :atom,
          required: true,
          doc: "Audience name as referenced in channel configurations"
        ],
        path: [
          type: {:list, :atom},
          required: true,
          doc: "Relationship path to follow for this audience (e.g., [:order, :user])"
        ]
      ]
    }
  end

  @doc """
  The `locales` entity for resource-level locale configuration.

  Defines which locales should have templates generated and serves as the
  default locale list for all events in the resource.
  """
  def locales_entity do
    %Entity{
      name: :locales,
      describe: """
      Configure locales for template generation and runtime locale resolution.

      When specified, the template generator (`mix ash.codegen`) will create
      locale-specific template variants for all events in this resource.

      ## Example

          dispatch do
            locales ["sv", "en"], default: "sv", locale_from: :visitor_locale

            event :created, trigger_on: :create do
              channels [
                [transport: :email, audience: :customer],
                [transport: :email, audience: :admin, locale: "sv"]
              ]
            end
          end

      This generates templates for each event:
      - email.html.heex (default/fallback)
      - email.sv.html.heex
      - email.en.html.heex

      At runtime:
      - Customer email uses lead.visitor_locale to select template
      - Admin email always uses Swedish template (channel-level override)
      """,
      args: [:locales],
      target: AshDispatch.Resource.Dsl.Locales,
      schema: [
        locales: [
          type: {:list, :string},
          required: true,
          doc: "List of locale codes (e.g., [\"sv\", \"en\", \"no\"])"
        ],
        default_locale: [
          type: :string,
          required: false,
          doc: """
          Default locale when none can be determined from the record.
          Falls back to AshDispatch config default_locale if not set.
          """
        ],
        locale_from: [
          type: :atom,
          required: false,
          doc: """
          Field on the resource to extract the runtime locale from.

          At dispatch time, this field is read from the record to determine
          which locale-specific template to render.

          Example: :visitor_locale, :preferred_language, :locale
          """
        ]
      ]
    }
  end

  @doc """
  The `counters` section for declaring resource-level counters.
  """
  def counters_section do
    %Section{
      name: :counters,
      describe: """
      Declare counters that auto-broadcast on action completion.

      Counters are resource-level concerns that track quantities (pending orders,
      unread notifications, etc.) and broadcast updates to users/admins in real-time.

      This eliminates manual counter broadcasting and centralizes counter definitions
      with the resources they count.
      """,
      entities: [counter_entity()],
      sections: []
    }
  end

  @doc """
  The `counter` entity for defining individual counters.
  """
  def counter_entity do
    %Entity{
      name: :counter,
      describe: """
      Declares a counter that broadcasts to users/admins when triggered.

      ## Example - User Counter

          counter :pending_orders do
            trigger_on [:create, :accept, :cancel]
            counter_name :pending_orders
            query_filter filter(status == :pending and user_id == ^user_id)
            audience :user
            invalidates ["orders"]
          end

      ## Example - Admin Counter

          counter :admin_pending_orders do
            trigger_on [:create, :accept, :cancel]
            counter_name :admin_pending_orders
            query_filter filter(status == :pending)  # No user scoping - total count
            audience :admin
            invalidates ["admin_orders"]
          end

      ## Example - Cross-Resource Counter

          counter :user_tickets do
            trigger_on [:create]
            resource MyApp.Tickets.Ticket  # Query a different resource
            counter_name :open_tickets
            query_filter filter(status in [:open, :in_progress] and user_id == ^user_id)
            audience :user
          end

      ## Advanced - Override in Event Module

      For complex counter logic, implement in your event module:

          # In lib/my_app/events/orders/created.ex
          def counters(%Context{data: %{order: order}}, %Channel{audience: :user}) do
            # Custom logic - return list of counter names to broadcast
            if order.requires_approval?, do: [:pending_approval], else: [:active_orders]
          end

      Note: Inline DSL handles most cases. Use event module overrides for
      conditional logic or when counter selection depends on runtime data.
      """,
      args: [:name],
      target: AshDispatch.Resource.Dsl.Counter,
      schema: [
        name: [
          type: :atom,
          required: true,
          doc: "Unique counter identifier in DSL (e.g., :pending_orders_counter)"
        ],
        trigger_on: [
          type: {:or, [:atom, {:list, :atom}]},
          required: true,
          doc: """
          Action name(s) that trigger this counter.
          Can be a single action or list of actions.
          """
        ],
        counter_name: [
          type: :atom,
          required: false,
          doc: """
          Counter name to broadcast after action completes.

          Examples:
          - User counters: `:pending_orders`, `:cart_items`
          - Admin counters: `:admin_pending_orders`, `:admin_active_users`
          """
        ],
        resource: [
          type: :atom,
          required: false,
          doc: """
          Ash resource module to query for counting.
          If not specified, defaults to the current resource.

          Example: MyApp.Orders.ProductOrder
          """
        ],
        query_filter: [
          type: :any,
          required: false,
          doc: """
          Ash.Query filter expression to count items.

          Examples:
          - filter(status == :pending)
          - filter(user_id == ^user_id and archived_at == nil)

          For `:user` audience, you can reference `^user_id` to scope to that user.
          For `:admin` audience, typically no user scoping (total count).
          """
        ],
        audience: [
          type: :atom,
          required: false,
          doc: """
          Audience who receives this counter broadcast.

          Use any audience atom configured in `:ash_dispatch, :recipient_filters`.
          AshDispatch supports 6 flexible audience formats:

          - **Bare atom** - `:user`, `:creator` (extract from relationship)
          - **Relationship + filter** - `admin: [:user, admin: true]`
          - **Relationship chain** - `sellers: [:user, :associated_seller]`
          - **Template filters** - Dynamic values from context
          - **Function/MFA** - Complex resolution logic
          - **System** - Static recipients

          See [Recipient Resolution](documentation/topics/recipient-resolution.md) for
          complete configuration guide and examples.
          """
        ],
        invalidates: [
          type: {:list, :string},
          default: [],
          doc: """
          Frontend query keys to invalidate when counter updates.

          Example: ["orders", "admin_tasks"]

          These keys are sent to the frontend in the broadcast metadata,
          allowing the UI to refetch relevant queries automatically.
          """
        ],
        user_id_path: [
          type: {:list, :atom},
          required: false,
          doc: """
          Relationship path to resolve user_id for `:user` audience counters.

          Use this when the resource doesn't have a direct `user_id` field,
          but has the user through a relationship chain.

          Example - CartItem counter (CartItem -> Cart -> User):

              counter :cart_items,
                trigger_on: [:create, :destroy],
                audience: :user,
                user_id_path: [:cart, :user_id]

          The system will:
          1. Load the `cart` relationship on CartItem
          2. Extract `user_id` from the loaded cart
          3. Use that user_id for broadcasting

          Defaults to nil (expects direct `user_id` field).
          """
        ],
        filter_by_record: [
          type: {:or, [:keyword_list, :map]},
          required: false,
          doc: """
          Filter the counted resource by a field from the triggering record.

          Use this when counting a different resource than the one triggering the counter.
          For example, counting CartItems when a Cart action is triggered.

          Format: [field: :target_field, record_field: :source_field]

          - `field` - Field in the counted resource to filter on
          - `record_field` - Field in the triggering record to use as filter value (defaults to :id)

          Example - Count CartItems when Cart.add_item is triggered:

              # In Cart resource
              counter :cart_items,
                trigger_on: [:add_item, :remove_item],
                resource: Magasin.Catalog.CartItem,
                filter_by_record: [field: :cart_id],
                audience: :user

          This counts CartItem records where `cart_id == triggering_cart.id`.

          Defaults to nil (no additional filtering by record).
          """
        ],
        group: [
          type: :atom,
          required: false,
          doc: """
          Counter group for organizing and TypeScript generation.

          Groups counters by domain/feature area. Used by the TypeScript generator
          to create organized type definitions and by frontend to access counters.

          Examples: :orders, :tickets, :requests, :cart

              counter :pending_orders,
                group: :orders,
                trigger_on: [:create, :complete],
                ...

          The TypeScript generator will create types like:

              type OrderCounters = {
                pending_orders: number;
                processing_orders: number;
              }
          """
        ],
        authorize?: [
          type: :boolean,
          default: true,
          doc: """
          Whether to use Ash authorization (policies) for counter queries.

          - `true` (default): Queries respect Ash policies, scoped via `scope` or `user_id_path`
          - `false`: Bypass policies, count ALL matching records (system-wide totals)

          Example - Admin counter for all pending orders:

              counter :admin_pending_orders,
                authorize?: false,
                trigger_on: [:create, :complete],
                query_filter: [status: :pending],
                audience: :admin,
                group: :orders

          For user-scoped counters with custom filtering, use `scope` instead:

              counter :my_assigned_tickets,
                audience: :admin,
                scope: expr(assigned_to_id == ^actor(:id))

          Defaults to true (counter uses Ash authorization).
          """
        ],
        scope: [
          type: {:or, [:any, nil]},
          required: false,
          doc: """
          Ash expression for scoping counter queries to the recipient.

          The `scope` option accepts any Ash expression and is evaluated with the
          broadcast recipient as the "actor". This enables powerful filtering:

          ## Expression Templates

          Use `^actor(:field)` to reference the recipient's attributes:

              # Simple: My orders
              scope: expr(user_id == ^actor(:id))

              # Regional: Orders in my region
              scope: expr(region == ^actor(:region))

              # Team: Tickets assigned to anyone in my team
              scope: expr(assigned_support.team_id == ^actor(:team_id))

              # Complex: Orders containing my products (seller)
              scope: expr(exists(items, product.seller_id == ^actor(:id)))

          ## Relationship with user_id_path

          The `user_id_path` option is syntactic sugar for simple scoping:

              # These are equivalent:
              user_id_path: [:user_id]
              scope: expr(user_id == ^actor(:id))

              # Nested paths also work:
              user_id_path: [:cart, :user_id]
              scope: expr(cart.user_id == ^actor(:id))

          If both `scope` and `user_id_path` are provided, `scope` takes precedence.

          ## When to Use scope vs user_id_path

          - **`user_id_path`**: Simple direct/nested user_id relationships
          - **`scope`**: Complex filtering (attributes, nested relationships, exists)

          Defaults to nil (uses `user_id_path` derivation if available).
          """
        ],
        aggregate: [
          type: :atom,
          required: false,
          doc: """
          Ash aggregate name to use instead of query_filter.

          When specified, uses an Ash aggregate defined on the resource
          instead of running a separate count query. This integrates with
          Ash's built-in authorization.

          Define the aggregate on your resource:

              aggregates do
                count :pending_order_count, :product_orders do
                  filter expr(status == :pending)
                end
              end

          Then reference it in your counter:

              counter :pending_orders,
                trigger_on: [:create, :complete],
                aggregate: :pending_order_count,
                audience: :user,
                group: :orders

          Benefits:
          - Leverages Ash's existing aggregate system
          - Authorization handled by aggregate definition
          - Can use complex calculations

          Note: When using aggregate, query_filter is ignored.
          """
        ]
      ]
    }
  end
end
