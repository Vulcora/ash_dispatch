defmodule AshDispatch.Info do
  @moduledoc """
  Introspection helpers for AshDispatch events.

  This module provides functions to introspect event DSL configuration
  at runtime. Generated automatically by `Spark.InfoGenerator`.

  ## Usage

      # Get event ID
      AshDispatch.Info.dispatch_id(MyApp.Events.Orders.Created)
      # => "orders.created"

      # Get channels
      AshDispatch.Info.dispatch_channels(MyApp.Events.Orders.Created)
      # => [%Channel{transport: :email, audience: :user}, ...]

      # Get domain
      AshDispatch.Info.dispatch_domain(MyApp.Events.Orders.Created)
      # => :orders

  ## Generated Functions

  All DSL options and sections generate corresponding accessor functions:

  ### Dispatch Section
  - `dispatch_id/1` - Event identifier
  - `dispatch_domain/1` - Event domain
  - `dispatch_category/1` - Email preference category
  - `dispatch_user_configurable?/1` - Whether user can opt-out

  ### Channels Section
  - `dispatch_channels/1` - List of channel entities

  ### Content Section
  - `dispatch_content_subject/1` - Email subject (if in DSL)
  - `dispatch_content_from_name/1` - From name
  - `dispatch_content_from_email/1` - From email
  - `dispatch_content_notification_title/1` - Notification title
  - `dispatch_content_notification_message/1` - Notification message
  - `dispatch_content_action_label/1` - Action button label
  - `dispatch_content_action_url/1` - Action URL

  ### Metadata Section
  - `dispatch_metadata_action_required?/1` - Whether action required
  - `dispatch_metadata_notification_type/1` - Notification type

  ### Counters Section
  - `dispatch_counters/1` - List of counter broadcast configurations
  """

  use Spark.InfoGenerator,
    extension: AshDispatch.Event,
    sections: [:dispatch]

  # Note: Spark.InfoGenerator will generate all accessor functions
  # based on the DSL schema defined in AshDispatch.Dsl.Sections
end
