defmodule AshDispatch.Test.PerTenant.Repo do
  @moduledoc """
  The repo the per-tenant tests run against. Started by
  `AshDispatch.Test.PerTenantCase`, which needs
  `ASH_DISPATCH_TEST_DATABASE_URL`.
  """
  use AshPostgres.Repo, otp_app: :ash_dispatch, warn_on_missing_ash_functions?: false

  def installed_extensions, do: []
  def min_pg_version, do: %Version{major: 15, minor: 0, patch: 0}
end

defmodule AshDispatch.Test.PerTenant.Notification do
  @moduledoc false
  use AshDispatch.Resources.Notification.Base,
    repo: AshDispatch.Test.PerTenant.Repo,
    domain: AshDispatch.Test.PerTenant.Domain,
    table: "pt_notifications",
    multitenancy: :context
end

defmodule AshDispatch.Test.PerTenant.Preference do
  @moduledoc false
  use AshDispatch.Resources.Preference.Base,
    repo: AshDispatch.Test.PerTenant.Repo,
    domain: AshDispatch.Test.PerTenant.Domain,
    table: "pt_preferences",
    multitenancy: :context
end

defmodule AshDispatch.Test.PerTenant.Receipt do
  @moduledoc false
  use AshDispatch.Resources.DeliveryReceipt.Base,
    repo: AshDispatch.Test.PerTenant.Repo,
    domain: AshDispatch.Test.PerTenant.Domain,
    notification_resource: AshDispatch.Test.PerTenant.Notification,
    table: "pt_receipts",
    multitenancy: :context

  policies do
    bypass always() do
      authorize_if always()
    end
  end
end

defmodule AshDispatch.Test.PerTenant.PublicReceipt do
  @moduledoc """
  The other half of the choice: receipts in the public schema, with the
  optional `tenant` column, for a host that wants to know which tenant a
  receipt was for without moving its receipts.
  """
  use AshDispatch.Resources.DeliveryReceipt.Base,
    repo: AshDispatch.Test.PerTenant.Repo,
    domain: AshDispatch.Test.PerTenant.Domain,
    notification_resource: AshDispatch.Test.PerTenant.Notification,
    table: "pt_public_receipts",
    tenant_column: true

  policies do
    bypass always() do
      authorize_if always()
    end
  end
end

defmodule AshDispatch.Test.PerTenant.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshDispatch.Test.PerTenant.Receipt
    resource AshDispatch.Test.PerTenant.PublicReceipt
    resource AshDispatch.Test.PerTenant.Notification
    resource AshDispatch.Test.PerTenant.Preference
  end
end

defmodule AshDispatch.Test.PerTenant.Tenants do
  @moduledoc """
  The host's answer to "which tenants exist", for the fixture: the two schemas
  `AshDispatch.Test.PerTenantCase` creates, unless a test narrows the list.
  """
  @behaviour AshDispatch.Tenants

  @impl true
  def all, do: Application.get_env(:ash_dispatch, :test_tenants, ["tenant_a", "tenant_b"])
end

defmodule AshDispatch.Test.PerTenant.Meeting do
  @moduledoc """
  A resource with events, so a whole dispatch can be run inside a tenant.
  Its own rows are not per tenant — the host's records are the host's business;
  what the library owns is the receipt, the notification and the preference.
  """
  use Ash.Resource,
    domain: AshDispatch.Test.PerTenant.Events,
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
    event :updated,
      trigger_on: :manual,
      module: AshDispatch.Test.PerTenant.MeetingUpdated,
      metadata: [category: :meetings],
      channels: [
        [transport: :in_app, audience: :user],
        [transport: :email, audience: :user]
      ]

    event :cancelled,
      trigger_on: :manual,
      module: AshDispatch.Test.PerTenant.MeetingCancelled,
      metadata: [category: :meetings, sensitive_content: true],
      channels: [
        [transport: :email, audience: :user]
      ]
  end
end

defmodule AshDispatch.Test.PerTenant.Events do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshDispatch.Test.PerTenant.Meeting
  end
end

defmodule AshDispatch.Test.PerTenant.EventHelpers do
  @moduledoc false
  defmacro __using__(id: id) do
    quote do
      use AshDispatch.Event

      @impl true
      def id, do: unquote(id)

      @impl true
      def recipients(%{data: data}, _channel), do: Map.get(data, :participants, [])

      @impl true
      def notification_title(_context, _channel), do: unquote(id)

      @impl true
      def notification_message(%{data: data}, _channel),
        do: "about #{data |> Map.get(:meeting, %{}) |> Map.get(:title)}"

      @impl true
      def subject(_context, _channel), do: unquote(id)
    end
  end
end

defmodule AshDispatch.Test.PerTenant.MeetingUpdated do
  @moduledoc false
  use AshDispatch.Test.PerTenant.EventHelpers, id: "pt_meeting.updated"
end

defmodule AshDispatch.Test.PerTenant.MeetingCancelled do
  @moduledoc false
  use AshDispatch.Test.PerTenant.EventHelpers, id: "pt_meeting.cancelled"
end

defmodule AshDispatch.Test.PerTenantCase do
  @moduledoc """
  Two tenants with real Postgres schemas, and the library configured to use
  them.

  `strategy :context` is a schema prefix, so there is no way to test it without
  schemas: a keyword list pretending to be a tenant proves only that a keyword
  list was passed. Every test using this template is tagged `:postgres` and
  needs `ASH_DISPATCH_TEST_DATABASE_URL`.
  """
  use ExUnit.CaseTemplate

  alias AshDispatch.Test.PerTenant

  @otp_app :ash_dispatch_per_tenant_test
  @tenants ["tenant_a", "tenant_b"]

  @per_tenant_resources [PerTenant.Receipt, PerTenant.Notification, PerTenant.Preference]

  @env [
    otp_app: @otp_app,
    domains: [PerTenant.Events],
    delivery_receipt_resource: PerTenant.Receipt,
    notification_resource: PerTenant.Notification,
    preference_resource: PerTenant.Preference,
    user_preference: AshDispatch.UserPreference.Resource,
    tenants: PerTenant.Tenants,
    repo: PerTenant.Repo,
    audiences: [:user, :admin],
    recipient_fields: [
      email: [identifier: :email],
      in_app: [identifier: :email]
    ],
    email_backend: AshDispatch.Test.PerTenant.Backend,
    capture_pid: nil
  ]

  using do
    quote do
      import AshDispatch.Test.PerTenantCase
      alias AshDispatch.Test.PerTenant
    end
  end

  setup do
    previous = Enum.map(@env, fn {key, _} -> {key, Application.fetch_env(:ash_dispatch, key)} end)
    previous_domains = Application.fetch_env(@otp_app, :ash_domains)

    start_supervised!(
      {PerTenant.Repo, url: System.fetch_env!("ASH_DISPATCH_TEST_DATABASE_URL"), pool_size: 4}
    )

    for tenant <- @tenants do
      AshDispatch.Test.Schema.create!(PerTenant.Repo, @per_tenant_resources, tenant)
    end

    AshDispatch.Test.Schema.drop_table!(PerTenant.Repo, PerTenant.PublicReceipt)
    AshDispatch.Test.Schema.create!(PerTenant.Repo, [PerTenant.PublicReceipt], nil)

    Enum.each(@env, fn {key, value} -> Application.put_env(:ash_dispatch, key, value) end)
    Application.put_env(:ash_dispatch, :capture_pid, self())
    Application.put_env(@otp_app, :ash_domains, [PerTenant.Events])

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:ash_dispatch, key, value)
        {key, :error} -> Application.delete_env(:ash_dispatch, key)
      end)

      case previous_domains do
        {:ok, value} -> Application.put_env(@otp_app, :ash_domains, value)
        :error -> Application.delete_env(@otp_app, :ash_domains)
      end

      Application.delete_env(:ash_dispatch, :test_tenants)
      AshDispatch.Test.Ets.stop(PerTenant.Meeting)
    end)

    :ok
  end

  @doc "The two tenants the fixture creates."
  def tenants, do: @tenants

  @doc "A recipient: a user id and an address, with no tenant of its own."
  def user(name \\ "user") do
    %{
      id: Ash.UUID.generate(),
      email: "#{name}-#{System.unique_integer([:positive])}@example.com"
    }
  end

  def meeting(title \\ "Planning"), do: %{id: Ash.UUID.generate(), title: title}

  @doc """
  Sends a manual event inside `tenant`. In-app channels only unless
  `:channels` says otherwise.
  """
  def send_event(event, tenant, participants, opts \\ []) do
    {data, opts} = Keyword.pop(opts, :data, %{})

    AshDispatch.Dispatcher.dispatch(
      "pt_meeting.#{event}",
      Map.merge(%{meeting: meeting(), participants: participants}, data),
      %{},
      opts
      |> Keyword.put(:tenant, tenant)
      |> Keyword.put_new(:channels, [%{transport: :in_app}])
    )
  end

  @doc "Every receipt in one tenant."
  def receipts(tenant) do
    PerTenant.Receipt |> Ash.read!(authorize?: false, tenant: tenant)
  end

  @doc "Every notification in one tenant."
  def notifications(tenant) do
    PerTenant.Notification |> Ash.read!(authorize?: false, tenant: tenant)
  end

  @doc "Every preference row in one tenant."
  def preferences(tenant) do
    PerTenant.Preference |> Ash.read!(authorize?: false, tenant: tenant)
  end

  @doc "Sets a preference row inside a tenant."
  def put_preference!(tenant, attrs) do
    PerTenant.Preference
    |> Ash.Changeset.for_create(:set, attrs)
    |> Ash.Changeset.set_tenant(tenant)
    |> Ash.create!(authorize?: false)
  end

  @doc "Creates a receipt directly, in a tenant — for the send-path tests."
  def receipt!(tenant, attrs) do
    PerTenant.Receipt
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          event_id: "pt_meeting.updated",
          transport: :email,
          audience: :user,
          recipient: "someone@example.com",
          subject: "Meeting",
          body_text: "The meeting moved"
        },
        attrs
      )
    )
    |> Ash.Changeset.set_tenant(tenant)
    |> Ash.create!(authorize?: false)
  end

  @doc "Every email the fixture backend was given, oldest first."
  def sent_emails(acc \\ []) do
    receive do
      {:pt_sent_email, params} -> sent_emails([params | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end

defmodule AshDispatch.Test.PerTenant.Backend do
  @moduledoc "Reports every send to the test process."

  def send_email(params) do
    case Application.get_env(:ash_dispatch, :capture_pid) do
      pid when is_pid(pid) -> send(pid, {:pt_sent_email, params})
      _ -> :ok
    end

    {:ok, %{id: "pt_#{System.unique_integer([:positive])}"}}
  end
end
