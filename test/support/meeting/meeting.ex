defmodule AshDispatch.Test.Meeting.Domain do
  @moduledoc """
  Fixture for the 0.8.8 dispatch options (`:actor`, `:tenant`) and
  `recipient_fields` `id:`: a manual event about a meeting, sent to its
  participants by email, with `exclude_actor: true`.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshDispatch.Test.Meeting.Meeting
    resource AshDispatch.Test.Meeting.ManualTrigger
  end
end

defmodule AshDispatch.Test.Meeting.ManualTrigger do
  @moduledoc false
  use AshDispatch.Resources.ManualTrigger.Base, domain: AshDispatch.Test.Meeting.Domain

  policies do
    bypass always() do
      authorize_if always()
    end
  end
end

defmodule AshDispatch.Test.Meeting.Meeting do
  @moduledoc false
  use Ash.Resource,
    domain: AshDispatch.Test.Meeting.Domain,
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

    update :rename do
      accept [:title]
    end
  end

  dispatch do
    event :updated,
      trigger_on: :manual,
      module: AshDispatch.Test.Meeting.Updated,
      channels: [
        [transport: :email, audience: :user, exclude_actor: true]
      ]

    # Action-triggered: the action's actor and tenant reach the context.
    event :renamed,
      trigger_on: :rename,
      module: AshDispatch.Test.Meeting.Renamed,
      channels: [
        [transport: :email, audience: :user, exclude_actor: true]
      ]
  end
end

defmodule AshDispatch.Test.Meeting.Updated do
  @moduledoc false
  use AshDispatch.Event

  @impl true
  def id, do: "meeting.updated"

  @impl true
  def recipients(%{data: data}, _channel), do: Map.get(data, :participants, [])

  @impl true
  def subject(%{data: data}, _channel), do: "Updated: #{title(data)}"

  @impl true
  def prepare_template_assigns(%{data: data}, _channel), do: %{title: title(data)}

  defp title(data), do: data |> Map.get(:meeting, %{}) |> Map.get(:title)
end

defmodule AshDispatch.Test.Meeting.Renamed do
  @moduledoc false
  use AshDispatch.Event

  @impl true
  def id, do: "meeting.renamed"

  @impl true
  def resource, do: AshDispatch.Test.Meeting.Meeting

  @impl true
  def data_key, do: :meeting

  @impl true
  def recipients(_context, _channel),
    do: Application.get_env(:ash_dispatch, :test_meeting_participants, [])

  @impl true
  def subject(%{data: %{meeting: meeting}}, _channel), do: "Renamed: #{meeting.title}"

  @impl true
  def prepare_template_assigns(%{data: %{meeting: meeting}}, _channel),
    do: %{title: meeting.title}
end

defmodule AshDispatch.Test.Meeting.RecordingChecker do
  @moduledoc """
  A preference checker that allows everything and reports what it was asked
  to the test process: `{:checked, user_id, event_id, transport, opts}`.
  """
  @behaviour AshDispatch.UserPreference

  @impl true
  def user_allows?(user_id, event_id, transport, opts) do
    case Application.get_env(:ash_dispatch, :capture_pid) do
      pid when is_pid(pid) -> send(pid, {:checked, user_id, event_id, transport, opts})
      _ -> :ok
    end

    true
  end
end

defmodule AshDispatch.Test.MeetingCase do
  @moduledoc """
  Configuration for the meeting tests: the `AshDispatch.Test.Meeting`
  fixtures registered, receipts in ETS, Oban inline, every email captured by
  `AshDispatch.Test.CaptureBackend`, preferences asked of
  `AshDispatch.Test.Meeting.RecordingChecker`.
  """
  use ExUnit.CaseTemplate

  @otp_app :ash_dispatch_meeting_test

  @env [
    otp_app: @otp_app,
    domains: [AshDispatch.Test.Meeting.Domain],
    delivery_receipt_resource: AshDispatch.Test.TransportReceipt,
    email_backend: AshDispatch.Test.CaptureBackend,
    user_preference: AshDispatch.Test.Meeting.RecordingChecker,
    recipient_fields: [email: [identifier: :email]],
    exclude_actor_on_manual_dispatch: nil,
    test_meeting_participants: nil,
    capture_pid: nil
  ]

  using do
    quote do
      import AshDispatch.Test.MeetingCase
    end
  end

  setup do
    previous = Enum.map(@env, fn {key, _} -> {key, Application.fetch_env(:ash_dispatch, key)} end)
    previous_domains = Application.fetch_env(@otp_app, :ash_domains)

    Enum.each(@env, fn
      {key, nil} -> Application.delete_env(:ash_dispatch, key)
      {key, value} -> Application.put_env(:ash_dispatch, key, value)
    end)

    Application.put_env(:ash_dispatch, :capture_pid, self())
    Application.put_env(@otp_app, :ash_domains, [AshDispatch.Test.Meeting.Domain])

    # As in `AshDispatch.Test.PreviewCase`: jobs run inside `Oban.insert/1`,
    # with nothing that needs a database.
    start_supervised!(
      {Oban,
       name: Oban,
       repo: AshDispatch.Test.Setup.Repo,
       engine: Oban.Engines.Inline,
       notifier: {Oban.Notifiers.Isolated, []},
       peer: {Oban.Peers.Isolated, [leader?: false]},
       plugins: [],
       queues: [],
       stager: false}
    )

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:ash_dispatch, key, value)
        {key, :error} -> Application.delete_env(:ash_dispatch, key)
      end)

      case previous_domains do
        {:ok, value} -> Application.put_env(@otp_app, :ash_domains, value)
        :error -> Application.delete_env(@otp_app, :ash_domains)
      end

      Ash.DataLayer.Ets.stop(AshDispatch.Test.TransportReceipt)
    end)

    :ok
  end

  def user(name \\ "user"),
    do: %{
      id: Ash.UUID.generate(),
      email: "#{name}-#{System.unique_integer([:positive])}@example.com"
    }

  @doc "Sends `meeting.updated` to `participants` through `Dispatcher.dispatch/4`."
  def send_updated(participants, opts \\ []) do
    AshDispatch.Dispatcher.dispatch(
      "meeting.updated",
      %{meeting: %{id: Ash.UUID.generate(), title: "Planning"}, participants: participants},
      %{},
      opts
    )
  end

  def receipts(event_id) do
    AshDispatch.Test.TransportReceipt
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.event_id == event_id))
  end

  @doc "The addresses of every email the capture backend received so far."
  def sent_to(acc \\ []) do
    receive do
      {:sent_email, params} -> sent_to([params.to | acc])
    after
      0 -> Enum.sort(acc)
    end
  end

  @doc "Every preference question the checker received so far, oldest first."
  def checks(acc \\ []) do
    receive do
      {:checked, user_id, event_id, transport, opts} ->
        checks([%{user_id: user_id, event_id: event_id, transport: transport, opts: opts} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
