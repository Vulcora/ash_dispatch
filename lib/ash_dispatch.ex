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
        # Must be endpoint-shaped (subscribe/1 + broadcast/3); see
        # `AshDispatch.Config.pubsub_module/0` for the contract. Do NOT
        # use a bare `Phoenix.PubSub` registered name like `MyApp.PubSub`.
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

  alias AshDispatch.Resources.ManualTrigger.Helpers

  @doc """
  Renders an event's channels without delivering anything.

  This is the preview engine behind the ManualTrigger resource, exposed as
  a plain function so an app can render a mail into an admin screen, a
  test, or a snapshot without going through a resource action.

  For each channel of the event it loads the event's record, runs the
  event's callbacks and renders its templates, returning one map per
  channel:

      %{
        channel: %{transport: :email, audience: :user},
        transport: :email,
        audience: :user,
        subject: "Your order is on its way",
        html_body: "<html>…</html>",
        text_body: "Your order …",
        from_address: "orders@example.com",
        recipient: "Alice <alice@example.com>",
        notification_title: nil,   # :in_app channels only
        notification_message: nil  # :in_app channels only
      }

  A channel whose `prepare_template_assigns/2` raises yields the same map
  with `html_body`/`text_body` `nil` and an extra `:error` key — one broken
  channel never takes the preview down.

  ## Parameters

  - `event_id` - event identifier, e.g. `"orders.created"`
  - `context_data` - the event's data. Pass `%{<data_key>_id => id}` (e.g.
    `%{order_id: id}`) to render a real record; pass `%{}` to fall back to
    the event module's `sample_data/0`, or to an arbitrary record from the
    database if it defines none.
  - `opts`:
    - `:audience` - only preview channels for this audience
    - `:transport` - only preview channels for this transport
    - `:actor` - actor used when loading the record (defaults to `nil`,
      i.e. an unauthorized read)
    - `:recipient_email` - display value for the `:recipient` field.
      Preview never sends, so this only changes what the preview shows.

  ## Returns

  - `{:ok, previews}` - a list with one map per matching channel (`[]` when
    the filters match no channel)
  - `{:error, reason}` - the event is unknown, or its record could not be
    loaded

  ## Examples

      # Every channel of the event, for one order
      {:ok, previews} = AshDispatch.preview("orders.created", %{order_id: order.id})

      # Just the customer's email
      {:ok, [preview]} =
        AshDispatch.preview("orders.created", %{order_id: order.id},
          transport: :email,
          audience: :user
        )

      preview.subject
      #=> "Order confirmation #1234"

  ## Note

  Preview renders; it does not deliver, create receipts or consult user
  preferences. To send, use `AshDispatch.Dispatcher.dispatch/3`.
  """
  @spec preview(String.t(), map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def preview(event_id, context_data \\ %{}, opts \\ []) do
    channel_filter =
      Helpers.build_channel_filter(Keyword.get(opts, :audience), Keyword.get(opts, :transport))

    Helpers.preview_trigger(
      event_id,
      context_data,
      channel_filter,
      Keyword.get(opts, :recipient_email),
      Keyword.get(opts, :actor)
    )
  end
end
