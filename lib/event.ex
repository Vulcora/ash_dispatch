defmodule AshDispatch.Event do
  @moduledoc """
  Behaviour and DSL for defining events.

  Events represent business occurrences that trigger notifications across
  multiple channels (email, in-app, Discord, etc.).

  ## Usage

  Define an event module:

      defmodule MyApp.Events.Orders.Created do
        use AshDispatch.Event

        dispatch do
          id "orders.created"
          domain :orders

          channels do
            channel :in_app, :user, time: :immediate
            channel :email, :user, time: 5.minutes(), skip_if_read: true
          end

          content do
            subject "Your order has been created"
            notification_title "Order created"
            notification_message "Order #\{\{order_number\}\} has been created"
          end
        end

        # Override for complex logic:
        def prepare_template_assigns(context, channel) do
          %{
            order_number: format_order_id(context.data.order)
          }
        end
      end

  ## Callbacks

  All callbacks are optional with sensible defaults. Override only what you need:

  ### Required (if not in DSL)
  - `id/0` - Event identifier
  - `channels/1` - List of delivery channels

  ### Content
  - `subject/2` - Email subject
  - `from/2` - Email from address
  - `notification_title/2` - In-app notification title
  - `notification_message/2` - In-app notification message

  ### Metadata
  - `domain/0` - Event domain
  - `category/1` - Email preference category
  - `user_configurable?/1` - Can users opt-out?
  - `notification_type/1` - Notification type (:info, :success, :warning, :error)

  ### Advanced
  - `recipients/2` - Get recipients for channel
  - `prepare_template_assigns/2` - Prepare template variables
  - `sample_data/0` - Sample data for previews
  - `generate_send_variables/2` - Generate real data for sending (tokens, URLs, etc.)
  - `counters/2` - Counters to broadcast

  See behaviour documentation for complete list.
  """

  alias AshDispatch.{Channel, Context}
  alias Spark.Dsl.Extension

  @type event_id :: String.t()
  @type context :: Context.t()
  @type channel :: Channel.t()
  @type recipient :: map()
  @type recipients :: [recipient()]

  # Behaviour callbacks

  @doc """
  Returns the unique event identifier.

  ## Example
      def id, do: "orders.created"
  """
  @callback id() :: event_id()

  @doc """
  Returns the event version (for future use).
  """
  @callback version() :: pos_integer()

  @doc """
  Returns the domain this event belongs to.

  ## Example
      def domain, do: :orders
  """
  @callback domain() :: atom()

  @doc """
  Returns the list of delivery channels for this event.

  ## Example
      def channels(_context) do
        [
          %Channel{transport: :in_app, audience: :user},
          %Channel{transport: :email, audience: :user, time: {:in, 300}}
        ]
      end
  """
  @callback channels(context()) :: [channel()]

  @doc """
  Returns the recipients for a specific channel.

  Default implementation delegates to RecipientResolver.from_audience/2.
  """
  @callback recipients(context(), channel()) :: recipients()

  @doc """
  Returns the email preference category for this event.

  Maps to UserEmailPreferences field. If nil, email is not user-configurable.
  """
  @callback category(context()) :: String.t() | nil

  @doc """
  Whether users can opt-out of this event via email preferences.
  """
  @callback user_configurable?(context()) :: boolean()

  @doc """
  Whether this event requires user action.
  """
  @callback action_required?(context()) :: boolean()

  @doc """
  Notification type for UI styling.
  """
  @callback notification_type(context()) :: :info | :success | :warning | :error

  @doc """
  Email subject line.

  Can be overridden per-channel via pattern matching:

      def subject(_ctx, %Channel{audience: :user}), do: "Your order"
      def subject(_ctx, %Channel{audience: :admin}), do: "New order"
  """
  @callback subject(context(), channel()) :: String.t()

  @doc """
  Email from address as {name, email} tuple.
  """
  @callback from(context(), channel()) :: {String.t(), String.t()}

  @doc """
  In-app notification title.
  """
  @callback notification_title(context(), channel()) :: String.t()

  @doc """
  In-app notification message.
  """
  @callback notification_message(context(), channel()) :: String.t()

  @doc """
  In-app notification action button label.
  """
  @callback action_label(context(), channel()) :: String.t() | nil

  @doc """
  In-app notification action URL.
  """
  @callback action_url(context(), channel()) :: String.t() | nil

  @doc """
  Prepare additional template assigns.

  Return a map that will be available in templates.

  ## Example
      def prepare_template_assigns(context, channel) do
        %{
          order_number: format_order_id(context.data.order),
          order_url: build_url(context.data.order, channel)
        }
      end
  """
  @callback prepare_template_assigns(context(), channel()) :: map()

  @doc """
  Sample data for event previews.

  Return a map with sample data matching the expected event data structure.

  ## Example
      def sample_data do
        %{
          order: MyApp.Factory.build(MyApp.Orders.Order),
          user: MyApp.Factory.build(MyApp.Accounts.User)
        }
      end
  """
  @callback sample_data() :: map()

  @doc """
  Counters to broadcast when this event creates notifications.

  Return list of counter atoms for specific channel.

  ## Example
      def counters(_ctx, %Channel{transport: :in_app, audience: :user}) do
        [:pending_orders, :cart_items]
      end

      def counters(_ctx, _channel), do: []
  """
  @callback counters(context(), channel()) :: [atom()]

  @doc """
  Whether this event is applicable for a specific user.

  Used by manual trigger to filter events based on user state.
  For example, only show email confirmation event if user is not confirmed.

  This callback is **only** used for filtering the manual trigger event list
  in admin UIs. It does NOT affect normal event dispatch.

  ## Example
      # Only show in manual trigger if user hasn't confirmed
      def applicable_for_user?(user) do
        is_nil(user.confirmed_at)
      end

      # Only show if user is archived
      def applicable_for_user?(user) do
        not is_nil(user.archived_at)
      end
  """
  @callback applicable_for_user?(user :: term()) :: boolean()

  @doc """
  Required resources for manual trigger.

  Declares which resources this event needs to render properly, along with
  optional Ash filters to restrict which records can be selected.

  Used by manual trigger UIs to show resource selectors. For example, an
  "order processed" event needs an Order resource, and should only show
  orders with status: :processed.

  Returns a keyword list where:
  - Key is the data key (e.g., :order, :ticket)
  - Value is either:
    - Just the resource module: `ProductOrder`
    - Tuple with module and filter: `{ProductOrder, filter: [status: :processed]}`

  ## Examples

      # Event needs an order, any status
      def required_resources do
        [order: Magasin.Orders.ProductOrder]
      end

      # Event needs a processed order only
      def required_resources do
        [order: {Magasin.Orders.ProductOrder, filter: [status: :processed]}]
      end

      # Event needs multiple resources
      def required_resources do
        [
          order: {Magasin.Orders.ProductOrder, filter: [status: :completed]},
          user: Magasin.Accounts.User
        ]
      end

      # Event needs no resources (just user context)
      def required_resources do
        []
      end

  The filter keyword list is passed directly to Ash queries, supporting any
  valid Ash filter syntax.
  """
  @callback required_resources() :: keyword(module() | {module(), keyword()})

  @doc """
  Returns the primary resource module for this event.

  This is used by the manual trigger system to know what resource to load.
  Mirrors the DSL pattern where events are defined on a resource.

  ## Example

      def resource, do: MyApp.Accounts.User
  """
  @callback resource() :: module()

  @doc """
  Returns the key to use for the resource in context.data.

  Defaults to deriving from the resource module name if not specified.

  ## Example

      def data_key, do: :user
  """
  @callback data_key() :: atom()

  @doc """
  Generate real variables for actual event dispatch (manual triggers, etc.).

  This callback is called when actually sending an event, allowing events to
  generate real data (tokens, URLs, etc.) instead of using sample data from
  `sample_data/0`.

  The callback receives:
  - `context` - The event context with loaded resource data
  - `opts` - The current variables map passed to dispatch

  Returns:
  - `{:ok, enhanced_opts}` - Success with enhanced variables map
  - `{:error, reason}` - Failure (will abort dispatch, not send with sample data)

  ## When it's called

  - **Manual triggers**: Always called when sending (not previewing)
  - **Normal dispatch**: Only called if variables are missing
  - **Previews**: Never called (uses `sample_data/0` instead)

  ## Security Note

  **IMPORTANT**: For security-critical events (password reset, magic links, invitations),
  always return `{:error, reason}` if token generation fails. Never send emails with
  sample/fallback tokens - this creates a security vulnerability!

  ## Example

  For password reset events that need real JWT tokens:

      def generate_send_variables(context, opts) do
        user = context.data[:user]

        # Only generate if not already provided
        if user && not Map.has_key?(opts, :reset_token) do
          case generate_password_reset_token(user) do
            {:ok, token} ->
              {:ok, Map.put(opts, :reset_token, token)}

            {:error, reason} ->
              # SECURITY: Fail dispatch instead of sending sample token!
              {:error, "Failed to generate password reset token: \#{inspect(reason)}"}
          end
        else
          {:ok, opts}
        end
      end

      defp generate_password_reset_token(user) do
        AshAuthentication.Jwt.token_for_user(user, %{
          purpose: :password_reset,
          token_lifetime: {24, :hours}
        })
      end

  For invitation events:

      def generate_send_variables(context, opts) do
        invited_user = context.data[:invited_user]

        if invited_user && not Map.has_key?(opts, :invitation_token) do
          case generate_invitation_token(invited_user) do
            {:ok, token} ->
              {:ok, Map.put(opts, :invitation_token, token)}

            {:error, reason} ->
              {:error, "Failed to generate invitation token: \#{inspect(reason)}"}
          end
        else
          {:ok, opts}
        end
      end

  ## Best practices

  - Always check if variable already exists before generating
  - Return `{:error, reason}` on generation failure for security-critical data
  - Use this for secure tokens, dynamic URLs, or time-sensitive data
  - Don't duplicate logic from normal action flows - they can provide variables directly
  - **Single Source of Truth**: Keep token generation logic ONLY in this callback,
    not scattered across RPC actions, senders, or other entry points
  """
  @callback generate_send_variables(context(), map()) :: {:ok, map()} | {:error, String.t()}

  @doc """
  Returns the URL path to the source resource for this event.

  This callback enables linking delivery receipts back to their source resources
  (e.g., linking an "order created" receipt to the order itself).

  The callback receives:
  - `context` - The event context with loaded resource data
  - `channel` - The channel being dispatched to (allows audience-specific paths)

  Returns:
  - `String.t()` - The URL path (e.g., "/admin/orders/uuid-here")
  - `nil` - If no source URL is applicable

  ## Pattern Matching on Audience

  Different audiences typically have different paths to the same resource:

      @impl true
      def source_url(context, %{audience: :admin}) do
        path = Application.get_env(:my_app, :app_paths)[:admin][:order]
        String.replace(path, ":id", to_string(context.data.order.id))
      end

      def source_url(context, %{audience: :user}) do
        path = Application.get_env(:my_app, :app_paths)[:user][:order]
        String.replace(path, ":id", to_string(context.data.order.id))
      end

      def source_url(_context, _channel), do: nil

  ## Usage

  The URL is computed at runtime via a calculation on DeliveryReceipt. This allows
  the same receipt to show different URLs based on who is viewing (admin vs user).

  To load the source URL on a receipt:

      receipt = Ash.load!(receipt, [:source_url])

  The calculation uses `source_type` and `source_id` (persisted on the receipt) to
  look up the event module and call this callback.
  """
  @callback source_url(context(), channel()) :: String.t() | nil

  # Optional advanced callbacks
  @callback template_variant(context(), channel()) :: atom() | nil
  @callback should_send?(context(), channel()) :: boolean()
  @callback prepare_data(any(), any()) :: map()
  @callback enrich_context(context(), channel()) :: context()

  # Define as optional
  @optional_callbacks [
    version: 0,
    domain: 0,
    category: 1,
    user_configurable?: 1,
    action_required?: 1,
    notification_type: 1,
    subject: 2,
    from: 2,
    notification_title: 2,
    notification_message: 2,
    action_label: 2,
    action_url: 2,
    prepare_template_assigns: 2,
    sample_data: 0,
    generate_send_variables: 2,
    source_url: 2,
    counters: 2,
    applicable_for_user?: 1,
    required_resources: 0,
    resource: 0,
    data_key: 0,
    template_variant: 2,
    should_send?: 2,
    prepare_data: 2,
    enrich_context: 2
  ]

  # Spark DSL Extension
  use Extension,
    sections: [AshDispatch.Dsl.Sections.dispatch_section()],
    transformers: [
      AshDispatch.Dsl.Transformers.InferEventId,
      AshDispatch.Dsl.Transformers.SetDefaults,
      AshDispatch.Dsl.Transformers.ValidateChannels
    ]

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour AshDispatch.Event

      use Spark.Dsl, default_extensions: [extensions: [unquote(__MODULE__)]]

      import AshDispatch.Channel, only: [channel: 2, channel: 3]

      # Default implementations that read from DSL first, then fallback

      @impl true
      def id do
        # Try to read from DSL
        case safe_get_dsl_opt(:id, [:dispatch]) do
          nil ->
            # Fallback: derive from module name
            __MODULE__
            |> Module.split()
            |> List.last()
            |> Macro.underscore()

          id ->
            id
        end
      end

      @impl true
      def version, do: 1

      @impl true
      def domain do
        safe_get_dsl_opt(:domain, [:dispatch])
      end

      @impl true
      def channels(context) do
        # Read channel entities from DSL (if module has DSL)
        if function_exported?(__MODULE__, :spark_is, 0) do
          case Spark.Dsl.Extension.get_entities(__MODULE__, [:dispatch, :channels]) do
            [] -> []
            channels -> channels
          end
        else
          []
        end
      rescue
        _ -> []
      end

      @impl true
      def recipients(context, channel) do
        # Smart default: automatically resolve recipients based on audience
        # Uses Ash introspection - no hardcoded patterns needed
        AshDispatch.Event.Helpers.resolve_recipients_for_audience(context, channel)
      end

      @impl true
      def category(_context) do
        safe_get_dsl_opt(:category, [:dispatch])
      end

      @impl true
      def user_configurable?(_context) do
        case safe_get_dsl_opt(:user_configurable?, [:dispatch]) do
          nil -> true
          value -> value
        end
      end

      @impl true
      def action_required?(_context) do
        case safe_get_dsl_opt(:action_required?, [:dispatch, :metadata]) do
          nil -> false
          value -> value
        end
      end

      @impl true
      def notification_type(_context) do
        case safe_get_dsl_opt(:notification_type, [:dispatch, :metadata]) do
          nil -> :info
          value -> value
        end
      end

      @impl true
      def subject(context, channel) do
        # Try DSL first (only if module has DSL configured)
        case safe_get_dsl_opt(:subject) do
          nil ->
            __static_subject()

          subject ->
            AshDispatch.Event.Interpolation.interpolate(subject, context, channel, __MODULE__)
        end
      end

      @impl true
      def from(_context, _channel) do
        from_name = safe_get_dsl_opt(:from_name)
        from_email = safe_get_dsl_opt(:from_email)

        case {from_name, from_email} do
          {nil, nil} -> __static_from()
          {name, email} -> {name || "App", email || "noreply@example.com"}
        end
      end

      @impl true
      def notification_title(context, channel) do
        case safe_get_dsl_opt(:notification_title) do
          nil ->
            __static_notification_title()

          title ->
            AshDispatch.Event.Interpolation.interpolate(title, context, channel, __MODULE__)
        end
      end

      @impl true
      def notification_message(context, channel) do
        case safe_get_dsl_opt(:notification_message) do
          nil ->
            __static_notification_message()

          message ->
            AshDispatch.Event.Interpolation.interpolate(message, context, channel, __MODULE__)
        end
      end

      @impl true
      def action_label(_context, _channel) do
        safe_get_dsl_opt(:action_label)
      end

      @impl true
      def action_url(context, channel) do
        case safe_get_dsl_opt(:action_url) do
          nil -> nil
          url -> AshDispatch.Event.Interpolation.interpolate(url, context, channel, __MODULE__)
        end
      end

      @impl true
      def prepare_template_assigns(_context, _channel), do: %{}

      @impl true
      def sample_data, do: %{}

      @impl true
      def counters(_context, _channel) do
        # Read from DSL counter broadcasts
        # For now, return empty list
        []
      end

      @impl true
      def applicable_for_user?(user) do
        # Try DSL filter first
        case safe_get_dsl_opt(:manual_trigger_filter, [:dispatch]) do
          nil ->
            # No DSL filter, default to true (show for all users)
            true

          filter ->
            # Use Ash query engine to evaluate filter against user
            AshDispatch.Event.Helpers.evaluate_user_filter(user, filter)
        end
      end

      @impl true
      def required_resources do
        # Default: event requires no additional resources beyond user context
        # Override to declare required resources with optional filters
        []
      end

      @impl true
      def template_variant(_context, _channel), do: nil

      @impl true
      def should_send?(context, channel) do
        # Try DSL filter first
        case safe_get_dsl_opt(:should_send_filter, [:dispatch]) do
          nil ->
            # No DSL filter, default to true (always send)
            true

          filter ->
            # Extract the target user (recipient) from the context
            # For should_send?, we need to evaluate against each recipient
            # This is a simplified version - full implementation would need to
            # evaluate per-recipient in the dispatcher
            case AshDispatch.Event.Helpers.extract_target_user(context, channel) do
              nil -> true
              user -> AshDispatch.Event.Helpers.evaluate_user_filter(user, filter)
            end
        end
      end

      @impl true
      def prepare_data(_changeset, _resource), do: %{}

      @impl true
      def enrich_context(context, _channel), do: context

      @impl true
      def source_url(context, channel) do
        # Default implementation using configured URL builder
        # Apps configure: config :ash_dispatch, url_builder: MyApp.UrlBuilder
        url_builder = Application.get_env(:ash_dispatch, :url_builder)

        if url_builder do
          # Get resource key from data_key callback (use apply to avoid compile-time warning)
          resource_key =
            if function_exported?(__MODULE__, :data_key, 0) do
              apply(__MODULE__, :data_key, [])
            else
              nil
            end

          if resource_key do
            resource = Map.get(context.data, resource_key)

            if resource && is_map(resource) && Map.has_key?(resource, :id) do
              try do
                url_builder.build_resource_url(
                  resource_key,
                  resource,
                  audience: channel.audience,
                  path_only: true
                )
              rescue
                # Gracefully handle missing path configs
                ArgumentError -> nil
              end
            end
          end
        end
      end

      # Helper to safely get DSL option (returns nil if module doesn't have DSL)
      defp safe_get_dsl_opt(opt_name, path \\ [:dispatch, :content]) do
        if function_exported?(__MODULE__, :spark_is, 0) do
          Spark.Dsl.Extension.get_opt(__MODULE__, path, opt_name, nil)
        else
          nil
        end
      rescue
        _ -> nil
      end

      # Private static defaults (can be overridden by defining these functions)
      defp __static_subject, do: "Notification"
      defp __static_from, do: {"App", "noreply@example.com"}
      defp __static_notification_title, do: "Notification"
      defp __static_notification_message, do: "You have a new notification"

      # Make everything overridable
      defoverridable id: 0,
                     version: 0,
                     domain: 0,
                     channels: 1,
                     recipients: 2,
                     category: 1,
                     user_configurable?: 1,
                     action_required?: 1,
                     notification_type: 1,
                     subject: 2,
                     from: 2,
                     notification_title: 2,
                     notification_message: 2,
                     action_label: 2,
                     action_url: 2,
                     prepare_template_assigns: 2,
                     sample_data: 0,
                     counters: 2,
                     applicable_for_user?: 1,
                     required_resources: 0,
                     template_variant: 2,
                     should_send?: 2,
                     prepare_data: 2,
                     enrich_context: 2,
                     source_url: 2
    end
  end
end
