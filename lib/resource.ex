defmodule AshDispatch.Resource do
  @moduledoc """
  Ash.Resource extension for defining event dispatching and counter broadcasting.

  This extension adds `dispatch` and `counters` sections to Ash resources, allowing
  you to define events and counters that are triggered by resource actions.

  ## Event Dispatching

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
        end

        counters do
          counter :pending_orders do
            trigger_on [:create_from_cart, :cancel]
            counter_name :pending_orders
            audience :user
            invalidates ["orders"]
          end
        end
      end

  ## Complex Events

  For events that need custom logic, reference a callback module:

      dispatch do
        event :created,
          trigger_on: :create_from_cart,
          module: MyApp.Events.OrderCreated
      end

  The callback module implements `AshDispatch.Event` behaviour.

  ## Auto-Injection

  The extension automatically injects changes into actions:
  - `DispatchEvent` for events specified in `dispatch` section
  - `BroadcastCounterUpdate` for counters specified in `counters` section

  You don't need to manually add these changes.

  ## Features

  - **Inline definitions** - Simple events/counters defined in the resource
  - **Auto-injection** - Changes automatically added to actions
  - **Type safety** - Compile-time validation of configurations
  - **Optional complexity** - Use callback modules when needed
  """

  use Spark.Dsl.Extension,
    sections: [
      AshDispatch.Resource.Dsl.dispatch_section(),
      AshDispatch.Resource.Dsl.counters_section()
    ],
    transformers: [
      AshDispatch.Resource.Transformers.ValidateEvents,
      AshDispatch.Resource.Transformers.InjectDispatchChanges,
      AshDispatch.Resource.Transformers.InjectCounterBroadcasts,
      AshDispatch.Resource.Transformers.InjectEntityNotifier
    ]

  @doc """
  Codegen callback for `mix ash.codegen` integration.

  Called automatically when running `mix ash.codegen`. Delegates to
  `mix ash_dispatch.gen` with the same arguments.
  """
  def codegen(args) do
    Mix.Task.reenable("ash_dispatch.gen")
    Mix.Task.run("ash_dispatch.gen", args)
  end
end
