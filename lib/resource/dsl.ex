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
      """,
      entities: [event_entity()],
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
          type: {:list, :atom},
          default: [],
          doc: """
          Relationships to preload before dispatching the event.
          """
        ],
        domain: [
          type: :atom,
          required: false,
          doc: "Event domain (e.g., :orders, :tickets). Defaults to resource domain."
        ],
        channels: [
          type: {:list, {:or, [:keyword_list, :map]}},
          default: [],
          doc: """
          List of delivery channels for this event. Each channel is a keyword list or map with:
          - transport: :email | :in_app | :discord | :sms | :slack | :webhook
          - audience: :user | :admin | custom atom
          - delay: optional delay in seconds
          - policy: :always | :skip_if_read (default: :always)
          - webhook_url: for webhook transport
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
        ]
      ]
    }
  end

end
