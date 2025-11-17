defmodule AshDispatch.Resources.Notification do
  @moduledoc """
  In-app notification resource for AshDispatch.

  Tracks user-facing notifications that appear in the application UI.

  ## Attributes

  - `title` - Short notification title
  - `message` - Full notification message
  - `action_url` - Optional URL to navigate to
  - `notification_type` - Visual type (:info, :success, :warning, :error)
  - `read` - Whether the user has read this notification
  - `read_at` - When the notification was read
  - `event_id` - Which event triggered this notification
  - `user_id` - Which user this notification is for

  ## Usage

  Notifications are created automatically by the InApp transport when
  events are dispatched with `transport: :in_app`.

  ```elixir
  # Query user's unread notifications
  notifications = AshDispatch.Resources.Notification
    |> Ash.Query.filter(expr(user_id == ^user.id and read == false))
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!()

  # Mark as read
  notification
    |> Ash.Changeset.for_update(:mark_read)
    |> Ash.update!()
  ```

  ## Relationships

  This resource intentionally has no relationships to keep it decoupled
  from your app's User resource. Consuming apps should define their own
  Notification resource if they need relationships:

  ```elixir
  defmodule MyApp.Notifications.Notification do
    use Ash.Resource,
      data_layer: AshPostgres.DataLayer

    # Copy attributes from AshDispatch.Resources.Notification
    # Add your own relationships:
    belongs_to :user, MyApp.Accounts.User
  end
  ```
  """

  use Ash.Resource,
    domain: AshDispatch.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :user_id,
        :event_id,
        :title,
        :message,
        :action_url,
        :notification_type
      ]
    end

    update :mark_read do
      accept []

      change fn changeset, _ ->
        changeset
        |> Ash.Changeset.change_attribute(:read, true)
        |> Ash.Changeset.change_attribute(:read_at, DateTime.utc_now())
      end
    end

    update :mark_unread do
      accept []

      change fn changeset, _ ->
        changeset
        |> Ash.Changeset.change_attribute(:read, false)
        |> Ash.Changeset.change_attribute(:read_at, nil)
      end
    end
  end

  attributes do
    uuid_primary_key :id

    # User identification (no relationship to stay decoupled)
    attribute :user_id, :uuid do
      public? true
      allow_nil? false
      description "User this notification is for"
    end

    # Event tracking
    attribute :event_id, :string do
      public? true
      allow_nil? false
      description "Event that triggered this notification (e.g., 'orders.created')"
    end

    # Notification content
    attribute :title, :string do
      public? true
      allow_nil? false
      description "Short notification title"
    end

    attribute :message, :string do
      public? true
      allow_nil? false
      description "Full notification message"
    end

    attribute :action_url, :string do
      public? true
      allow_nil? true
      description "Optional URL to navigate to when clicking notification"
    end

    attribute :notification_type, :atom do
      public? true
      allow_nil? false
      default :info
      constraints one_of: [:info, :success, :warning, :error]
      description "Visual type of notification for UI styling"
    end

    # Read tracking
    attribute :read, :boolean do
      public? true
      allow_nil? false
      default false
      description "Whether the user has read this notification"
    end

    attribute :read_at, :utc_datetime_usec do
      public? true
      allow_nil? true
      description "When the notification was read"
    end

    timestamps(public?: true)
  end

  code_interface do
    define :create
    define :mark_read
    define :mark_unread
    define :read, action: :read
  end
end
