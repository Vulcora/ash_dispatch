defmodule AshDispatch.Test.Inbox.Domain do
  @moduledoc """
  Fixture for the 0.9.0 notification features: a notification resource and
  a preference resource built from the library's bases (on ETS), and manual
  events about a meeting, sent through `Dispatcher.dispatch/4`.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshDispatch.Test.Inbox.Meeting
    resource AshDispatch.Test.Inbox.Notification
    resource AshDispatch.Test.Inbox.Preference
    resource AshDispatch.Test.Inbox.ManualTrigger
  end
end

defmodule AshDispatch.Test.Inbox.ManualTrigger do
  @moduledoc false
  use AshDispatch.Resources.ManualTrigger.Base, domain: AshDispatch.Test.Inbox.Domain

  policies do
    bypass always() do
      authorize_if always()
    end
  end
end

defmodule AshDispatch.Test.Inbox.Notification do
  @moduledoc false
  use AshDispatch.Resources.Notification.Base,
    repo: AshDispatch.Test.Setup.Repo,
    domain: AshDispatch.Test.Inbox.Domain,
    data_layer: Ash.DataLayer.Ets
end

defmodule AshDispatch.Test.Inbox.Preference do
  @moduledoc false
  use AshDispatch.Resources.Preference.Base,
    repo: AshDispatch.Test.Setup.Repo,
    domain: AshDispatch.Test.Inbox.Domain,
    data_layer: Ash.DataLayer.Ets

  # Every read reports to the test process, so a test can count queries.
  preparations do
    prepare fn query, _context ->
      case Application.get_env(:ash_dispatch, :capture_pid) do
        pid when is_pid(pid) -> send(pid, {:preference_read, query.action.name})
        _ -> :ok
      end

      query
    end
  end
end

defmodule AshDispatch.Test.Inbox.Meeting do
  @moduledoc false
  use Ash.Resource,
    domain: AshDispatch.Test.Inbox.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshDispatch.Resource]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true
  end

  actions do
    defaults [:read, create: [:title]]
  end

  dispatch do
    # Sent to every participant; whoever made the change is left out.
    event :updated,
      trigger_on: :manual,
      module: AshDispatch.Test.Inbox.MeetingUpdated,
      metadata: [category: :meetings],
      channels: [
        [transport: :in_app, audience: :user, exclude_actor: true],
        [transport: :email, audience: :user, exclude_actor: true]
      ]

    # Mandatory: never gated, shown locked.
    event :cancelled,
      trigger_on: :manual,
      module: AshDispatch.Test.Inbox.MeetingCancelled,
      metadata: [category: :meetings, user_configurable: false],
      channels: [
        [transport: :in_app, audience: :user]
      ]

    # Email is off unless someone switches it on.
    event :starting_soon,
      trigger_on: :manual,
      module: AshDispatch.Test.Inbox.MeetingStartingSoon,
      metadata: [category: :reminders, preference_default: [email: false]],
      channels: [
        [transport: :in_app, audience: :user],
        [transport: :email, audience: :user]
      ]

    # Goes to the admins only: not offered in a settings screen.
    event :flagged,
      trigger_on: :manual,
      module: AshDispatch.Test.Inbox.MeetingFlagged,
      channels: [
        [transport: :in_app, audience: :admin]
      ]
  end
end

defmodule AshDispatch.Test.Inbox.EventHelpers do
  @moduledoc false
  defmacro __using__(id: id) do
    quote do
      use AshDispatch.Event

      @impl true
      def id, do: unquote(id)

      @impl true
      def recipients(%{data: data}, _channel), do: Map.get(data, :participants, [])

      @impl true
      def notification_title(%{data: data}, _channel),
        do: "#{unquote(id)}: #{data |> Map.get(:meeting, %{}) |> Map.get(:title)}"

      @impl true
      def notification_message(_context, _channel), do: "Something happened"

      @impl true
      def subject(_context, _channel), do: unquote(id)
    end
  end
end

defmodule AshDispatch.Test.Inbox.MeetingUpdated do
  @moduledoc false
  use AshDispatch.Test.Inbox.EventHelpers, id: "meeting.updated"
end

defmodule AshDispatch.Test.Inbox.MeetingCancelled do
  @moduledoc false
  use AshDispatch.Test.Inbox.EventHelpers, id: "meeting.cancelled"
end

defmodule AshDispatch.Test.Inbox.MeetingStartingSoon do
  @moduledoc false
  use AshDispatch.Test.Inbox.EventHelpers, id: "meeting.starting_soon"
end

defmodule AshDispatch.Test.Inbox.MeetingFlagged do
  @moduledoc false
  use AshDispatch.Test.Inbox.EventHelpers, id: "meeting.flagged"
end

defmodule AshDispatch.Test.InboxCase do
  @moduledoc """
  Configuration for the inbox tests: the `AshDispatch.Test.Inbox` fixtures
  registered, receipts and notifications in ETS, preferences read from the
  ETS preference resource, broadcasts captured by `AshDispatch.Test.InboxPubSub`.
  """
  use ExUnit.CaseTemplate

  @otp_app :ash_dispatch_inbox_test

  @env [
    otp_app: @otp_app,
    domains: [AshDispatch.Test.Inbox.Domain],
    delivery_receipt_resource: AshDispatch.Test.TransportReceipt,
    notification_resource: AshDispatch.Test.Inbox.Notification,
    preference_resource: AshDispatch.Test.Inbox.Preference,
    user_preference: AshDispatch.UserPreference.Resource,
    pubsub_module: AshDispatch.Test.InboxPubSub,
    audiences: [:user, :admin],
    recipient_fields: [
      email: [identifier: :email],
      in_app: [identifier: :email]
    ],
    capture_pid: nil
  ]

  using do
    quote do
      import AshDispatch.Test.InboxCase
      alias AshDispatch.Test.Inbox.{Notification, Preference}
    end
  end

  setup do
    previous = Enum.map(@env, fn {key, _} -> {key, Application.fetch_env(:ash_dispatch, key)} end)
    previous_domains = Application.fetch_env(@otp_app, :ash_domains)

    Enum.each(@env, fn {key, value} -> Application.put_env(:ash_dispatch, key, value) end)
    Application.put_env(:ash_dispatch, :capture_pid, self())
    Application.put_env(@otp_app, :ash_domains, [AshDispatch.Test.Inbox.Domain])

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:ash_dispatch, key, value)
        {key, :error} -> Application.delete_env(:ash_dispatch, key)
      end)

      case previous_domains do
        {:ok, value} -> Application.put_env(@otp_app, :ash_domains, value)
        :error -> Application.delete_env(@otp_app, :ash_domains)
      end

      for resource <- [
            AshDispatch.Test.Inbox.Notification,
            AshDispatch.Test.Inbox.Preference,
            AshDispatch.Test.TransportReceipt
          ] do
        Ash.DataLayer.Ets.stop(resource)
      end
    end)

    :ok
  end

  def user(name \\ "user"),
    do: %{
      id: Ash.UUID.generate(),
      email: "#{name}-#{System.unique_integer([:positive])}@example.com"
    }

  def meeting(title \\ "Planning"), do: %{id: Ash.UUID.generate(), title: title}

  @doc "Sends a manual meeting event, in-app channels only."
  def send_event(event, participants, opts \\ []) do
    {data, opts} = Keyword.pop(opts, :data, %{})

    AshDispatch.Dispatcher.dispatch(
      "meeting.#{event}",
      Map.merge(%{meeting: meeting(), participants: participants}, data),
      %{},
      Keyword.put_new(opts, :channels, [%{transport: :in_app}])
    )
  end

  def receipts(event_id) do
    AshDispatch.Test.TransportReceipt
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.event_id == event_id))
  end

  def notifications_for(user_id) do
    AshDispatch.Test.Inbox.Notification
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.user_id == user_id))
  end

  def put_preference!(attrs) do
    AshDispatch.Test.Inbox.Preference
    |> Ash.Changeset.for_create(:set, attrs)
    |> Ash.create!(authorize?: false)
  end

  @doc "Every broadcast the pubsub received so far, oldest first."
  def broadcasts(acc \\ []) do
    receive do
      {:broadcast, topic, event, payload} -> broadcasts([{topic, event, payload} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end

defmodule AshDispatch.Test.InboxPubSub do
  @moduledoc """
  An endpoint-shaped pubsub (`subscribe/1`, `broadcast/3`) for tests:
  broadcasts go to `:capture_pid` as `{:broadcast, topic, event, payload}`,
  subscriptions as `{:subscribed, topic}`.
  """

  def subscribe(topic) do
    notify({:subscribed, topic})
    :ok
  end

  def broadcast(topic, event, payload) do
    notify({:broadcast, topic, event, payload})
    :ok
  end

  defp notify(message) do
    case Application.get_env(:ash_dispatch, :capture_pid) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end
end
