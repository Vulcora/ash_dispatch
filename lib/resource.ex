defmodule AshDispatch.Resource do
  @moduledoc """
  Ash.Resource extension for defining event dispatching.

  This extension adds a `dispatch` section to Ash resources, allowing you to
  define events that are triggered by resource actions.

  ## Usage

      defmodule MyApp.Orders.ProductOrder do
        use Ash.Resource,
          extensions: [AshDispatch.Resource]

        actions do
          create :create_from_cart do
            # ... action logic ...
          end
        end

        dispatch do
          event :created,
            trigger_on: :create_from_cart,
            channels: [
              [transport: :in_app, audience: :user],
              [transport: :email, audience: :user, delay: 300]
            ],
            content: [
              subject: "Order created",
              notification_title: "Order created"
            ]

          event :cancelled,
            trigger_on: :cancel,
            channels: [
              [transport: :email, audience: :user]
            ],
            content: [
              subject: "Order cancelled"
            ]
        end
      end

  ## Complex Events

  For events that need custom logic, reference a callback module:

      dispatch do
        event :created,
          trigger_on: :create_from_cart,
          module: MyApp.Events.OrderCreated
      end

  The callback module implements `AshDispatch.Event` behaviour (without DSL).

  ## Auto-Dispatch

  The extension automatically injects a `DispatchEvent` change into actions
  specified by `trigger_on`. You don't need to manually add the change.

  ## Features

  - **Inline event definitions** - Simple events defined right in the resource
  - **Auto-dispatch** - Events automatically triggered by actions
  - **Type safety** - Compile-time validation of event configurations
  - **Optional complexity** - Use callback modules when needed
  """

  use Spark.Dsl.Extension,
    sections: [AshDispatch.Resource.Dsl.dispatch_section()],
    transformers: [
      AshDispatch.Resource.Transformers.ValidateEvents,
      AshDispatch.Resource.Transformers.InjectDispatchChanges
    ]
end
