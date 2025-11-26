defmodule AshDispatch do
  @moduledoc """
  Event-driven notification system for Ash Framework.

  AshDispatch provides a declarative way to define and dispatch events
  across multiple transport types (email, in-app notifications, SMS,
  webhooks, etc.) with full Ash integration.

  ## Key Components

  - `AshDispatch.Event` - Behaviour for defining event modules
  - `AshDispatch.Resource` - Ash extension for inline event definitions
  - `AshDispatch.Dispatcher` - Main entry point for dispatching events
  - `AshDispatch.Introspection` - DSL introspection utilities

  ## Configuration

      config :ash_dispatch,
        otp_app: :my_app,
        repo: MyApp.Repo,
        mailer: MyApp.Mailer,
        endpoint: MyAppWeb.Endpoint,
        pubsub_module: MyAppWeb.Endpoint,
        user_resource: MyApp.Accounts.User,
        user_domain: MyApp.Accounts

  ## Usage

  ### Inline DSL (in resources)

      defmodule MyApp.Orders.ProductOrder do
        use Ash.Resource,
          extensions: [AshDispatch.Resource]

        dispatch do
          event :created do
            trigger_on [:create]
            channels do
              channel :email, :user
              channel :in_app, :user
            end
          end
        end
      end

  ### Standalone Event Modules

      defmodule MyApp.Events.Orders.Created.Event do
        use AshDispatch.Event

        dispatch do
          id "orders.created"
          domain :orders
          channels do
            channel :email, :user
            channel :email, :admin, variant: :admin
          end
        end
      end

  ## Code Generation

  Run `mix ash_dispatch.gen` to generate missing files based on DSL definitions:
  - Templates for email channels
  - Event module stubs for inline events
  - TypeScript types for frontend integration
  """
end
