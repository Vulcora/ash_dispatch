defmodule AshDispatch.Dsl.Sections do
  @moduledoc """
  Defines the DSL sections for AshDispatch events.

  This module contains the Spark DSL section and entity definitions for:
  - `dispatch` - Main event configuration
  - `channels` - Channel definitions (transport + audience + timing)
  - `content` - Simple content definitions (subject, title, etc.)
  - `metadata` - Event metadata (category, notification_type, etc.)
  - `counters` - Counter broadcasting configuration
  """

  alias Spark.Dsl.{Entity, Section}

  @doc """
  The main `dispatch` section that contains all event configuration.
  """
  def dispatch_section do
    %Section{
      name: :dispatch,
      describe: """
      Configure event dispatching, channels, and content.

      The dispatch section allows you to define all aspects of an event:
      metadata, channels, content, and counters.
      """,
      schema: [
        id: [
          type: :string,
          required: false,
          doc: """
          Unique event identifier (e.g., "orders.created").
          If not provided, defaults to "{module_name_last_segment}".
          """
        ],
        domain: [
          type: :atom,
          required: false,
          doc: """
          Domain this event belongs to (e.g., :orders, :tickets).
          Used for organization and filtering.
          """
        ],
        category: [
          type: :string,
          required: false,
          doc: """
          Email preference category for user opt-out.
          Maps to UserEmailPreferences field.
          If nil, email is not user-configurable.
          """
        ],
        user_configurable?: [
          type: :boolean,
          default: true,
          doc: """
          Whether users can opt-out of this event via email preferences.
          Set to false for critical system emails (auth, password reset).
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

          Defaults to no filter (show for all users). For complex logic, override
          the `applicable_for_user?/1` callback instead.
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

          Defaults to no filter (always send). For complex logic, override
          the `should_send?/2` callback instead.

          Note: This filter is only checked for auto-triggered events. Manual
          triggers always send (assuming applicable_for_user? returns true).
          """
        ]
      ],
      sections: [
        channels_section(),
        content_section(),
        metadata_section(),
        counters_section(),
        recipient_section()
      ]
    }
  end

  @doc """
  The `channels` section for defining delivery channels.
  """
  def channels_section do
    %Section{
      name: :channels,
      describe: """
      Define delivery channels for this event.

      Each channel specifies transport type, audience, timing, and policies.
      """,
      entities: [channel_entity()]
    }
  end

  @doc """
  The `channel` entity definition.
  """
  def channel_entity do
    %Entity{
      name: :channel,
      describe: """
      Define a delivery channel.

      Channels specify how and when to deliver notifications.
      """,
      args: [:transport, :audience],
      target: AshDispatch.Dsl.Channel,
      schema: [
        transport: [
          type: {:in, [:email, :in_app, :discord, :sms, :slack, :webhook]},
          required: true,
          doc: "Transport type for this channel"
        ],
        audience: [
          type: :atom,
          required: true,
          doc: "Audience for this channel (:user, :admin, or custom)"
        ],
        time: [
          type: :any,
          default: {:in, 0},
          doc: """
          When to deliver this channel.
          Options:
          - :immediate or {:in, 0} - Send immediately
          - {:in, seconds} - Delay by seconds
          - {:at, DateTime.t()} - Send at specific time
          - {:window, map()} - Send within time window
          """
        ],
        policy: [
          type: {:in, [:always, :skip_if_read]},
          default: :always,
          doc: """
          Delivery policy.
          - :always - Always send
          - :skip_if_read - Skip if linked in-app notification was read
          """
        ],
        variant: [
          type: :atom,
          required: false,
          doc: """
          Template variant to use (e.g., :admin for admin-specific templates).
          """
        ],
        webhook_url: [
          type: :string,
          required: false,
          doc: "Webhook URL for Discord/Slack/custom webhooks"
        ],
        opts: [
          type: :map,
          default: %{},
          doc: "Transport-specific options"
        ],
        counters: [
          type: {:list, :atom},
          default: [],
          doc: """
          List of counter names to broadcast when this channel creates a notification.
          E.g., [:admin_pending_reseller_requests, :user_cart_items]
          """
        ]
      ]
    }
  end

  @doc """
  The `content` section for simple content definitions.
  """
  def content_section do
    %Section{
      name: :content,
      describe: """
      Define simple content for this event.

      For static or simple interpolated content, use this section.
      For complex logic, override callbacks instead.
      """,
      schema: [
        subject: [
          type: :string,
          required: false,
          doc: """
          Email subject line.
          Supports {{variable}} interpolation from prepare_template_assigns/2.
          """
        ],
        from_name: [
          type: :string,
          required: false,
          doc: "Email 'from' name (e.g., 'MyApp')"
        ],
        from_email: [
          type: :string,
          required: false,
          doc: "Email 'from' address (e.g., 'noreply@myapp.com')"
        ],
        notification_title: [
          type: :string,
          required: false,
          doc: """
          In-app notification title.
          Supports {{variable}} interpolation.
          """
        ],
        notification_message: [
          type: :string,
          required: false,
          doc: """
          In-app notification message.
          Supports {{variable}} interpolation.
          """
        ],
        action_label: [
          type: :string,
          required: false,
          doc: "Action button label for in-app notifications"
        ],
        action_url: [
          type: :string,
          required: false,
          doc: """
          Action URL for in-app notifications.
          Supports {{variable}} interpolation.
          """
        ]
      ]
    }
  end

  @doc """
  The `metadata` section for event metadata.
  """
  def metadata_section do
    %Section{
      name: :metadata,
      describe: """
      Define event metadata.
      """,
      schema: [
        action_required?: [
          type: :boolean,
          default: false,
          doc: "Whether this event requires user action"
        ],
        notification_type: [
          type: {:in, [:info, :success, :warning, :error]},
          default: :info,
          doc: "Notification type for styling in UI"
        ]
      ]
    }
  end

  @doc """
  The `counters` section for counter broadcasting configuration.
  """
  def counters_section do
    %Section{
      name: :counters,
      describe: """
      Define which counters to broadcast when this event creates notifications.
      """,
      entities: [counter_broadcast_entity()]
    }
  end

  @doc """
  The `counter_broadcast` entity for specifying counter broadcasts.
  """
  def counter_broadcast_entity do
    %Entity{
      name: :broadcast_counters,
      describe: """
      Broadcast counters for specific channels.
      """,
      args: [:counter_names],
      target: AshDispatch.Dsl.CounterBroadcast,
      schema: [
        counter_names: [
          type: {:list, :atom},
          required: true,
          doc: "List of counter names to broadcast"
        ],
        on_transport: [
          type: {:list, :atom},
          required: false,
          doc: "Only broadcast for these transport types (e.g., [:in_app])"
        ],
        on_audience: [
          type: {:list, :atom},
          required: false,
          doc: "Only broadcast for these audiences (e.g., [:user])"
        ]
      ]
    }
  end

  @doc """
  The `recipient` section for configuring recipient field extraction.
  """
  def recipient_section do
    %Section{
      name: :recipient,
      describe: """
      Configure how to extract recipient identifiers and names from recipient structs.

      This section allows per-transport overrides for the event. The configuration
      cascades from most specific to least specific:

      1. Event DSL override (this section) - Most specific
      2. Audience + Transport config (application config)
      3. Transport config (application config)
      4. Generic default (application config)
      5. Error if no config found

      ## Example

          dispatch do
            # Override identifier field for email transport in this event
            recipient do
              email do
                identifier :primary_email
                name :full_name
              end

              sms do
                identifier :mobile_phone
              end
            end
          end

      ## Application Config

      The global defaults are configured in config/config.exs:

          config :ash_dispatch,
            recipient_fields: [
              # Generic defaults (work for all transports)
              identifier: :email,
              name: :contact_person,

              # Per-transport overrides (optional)
              sms: [
                identifier: :mobile_phone,
                name: :first_name
              ],

              # Per-audience overrides (optional)
              audiences: [
                admin: [
                  name: :full_name
                ],
                lead: [
                  identifier: :primary_email,
                  name: :company_name
                ]
              ]
            ]

      ## Field Extraction Formats

      Field values support multiple formats:

      - `:field_name` - Direct atom field access
      - `{:field, :field_name}` - Explicit field tuple
      - `{:field, [:nested, :path]}` - Nested field access via get_in/2
      - `{:string_field, "key"}` - String key access for JSON data
      - `&Module.function/1` - Custom extraction function
      - `nil` - No field (e.g., webhooks don't need names)
      """,
      sections: [
        recipient_transport_section(:email),
        recipient_transport_section(:in_app),
        recipient_transport_section(:sms),
        recipient_transport_section(:discord),
        recipient_transport_section(:slack),
        recipient_transport_section(:webhook)
      ]
    }
  end

  @doc """
  Creates a transport-specific recipient configuration section.
  """
  def recipient_transport_section(transport) do
    %Section{
      name: transport,
      describe: """
      Configure recipient field extraction for #{transport} transport.
      """,
      schema: [
        identifier: [
          type: :any,
          required: false,
          doc: """
          Field specification for extracting the recipient identifier (email, phone, etc.).

          Formats:
          - `:field_name` - Direct field access
          - `{:field, :field_name}` - Explicit field
          - `{:field, [:nested, :path]}` - Nested path
          - `{:string_field, "key"}` - String key
          - `&Module.function/1` - Custom function
          """
        ],
        name: [
          type: :any,
          required: false,
          doc: """
          Field specification for extracting the recipient display name.

          Formats: Same as identifier.
          Set to `nil` if name is not needed (e.g., webhooks).
          """
        ]
      ]
    }
  end
end
