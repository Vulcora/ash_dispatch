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
      entities: [event_entity(), audience_prefix_entity(), audience_entity()],
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

      ## Examples

      Simple inline event with data-based config:

          event :created,
            trigger_on: :create_from_cart,
            channels: [
              [transport: :in_app, audience: :user],
              [transport: :email, audience: :user, delay: 300]
            ],
            content: [
              subject: "Order created",
              notification_title: "Your order was created"
            ],
            metadata: [
              notification_type: :success
            ]

      Event with callback module (for complex logic):

          event :created,
            trigger_on: :create_from_cart,
            module: MyApp.Events.OrderCreated
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
          Action name(s) that trigger this event.
          Can be a single action or list of actions.
          """
        ],
        module: [
          type: :atom,
          required: false,
          doc: """
          Optional callback module that implements AshDispatch.Event behaviour.
          If not specified, uses inline DSL configuration.
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
          - `webhook_url`: For webhook transport
          - `content`: Transport-specific content (see below)
          - `metadata`: Transport-specific metadata (see below)

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

          Valid values:
          - `:user` - Broadcast to specific user (query scoped to their user_id)
          - `:admin` - Broadcast to all admin users (query recipients via recipient_filters config)
          - `:system` - Broadcast to all connected users (rare)
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
        global?: [
          type: :boolean,
          default: false,
          doc: """
          Whether this is a global counter (bypasses policies, no user scoping).

          Global counters:
          - Always use `authorize?: false` for queries
          - Don't scope queries by user_id
          - Suitable for admin counters that need system-wide totals

          Example - Admin counter for all pending orders:

              counter :admin_pending_orders,
                global?: true,
                trigger_on: [:create, :complete],
                query_filter: [status: :pending],
                audience: :admin,
                group: :orders

          Defaults to false (counter uses authorization and user scoping).
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
