defmodule AshDispatch.UserPreference.Resource do
  @moduledoc """
  The standard preference checker: reads a resource built on
  `AshDispatch.Resources.Preference.Base`.

      config :ash_dispatch,
        user_preference: AshDispatch.UserPreference.Resource,
        preference_resource: MyApp.Notifications.Preference

  ## One query per dispatch

  The dispatcher hands every channel's recipients to `prefetch/2` before
  the receipts are created. It reads, in one query, the tenant's rows for
  the event and its category — the tenant defaults and the rows of exactly
  those recipients — and keeps them for the rest of the dispatch, every
  transport included. `user_allows?/4` then answers from memory. A second
  channel to the same people costs nothing; one to new people reads only
  theirs. Outside a dispatch (a direct `AshDispatch.UserPreference.allows_user?/4`)
  each call reads what it needs.

  ## Precedence

  The person's row beats the tenant's, the tenant's beats the event's own
  default; at each level a row for the event beats one for its category.
  See `AshDispatch.Resources.Preference.Base`.

  ## For a settings screen

  - `configurable_events/0` — the events a person can switch, with their
    category, transports and defaults
  - `settings/2` — every configurable event × transport with the answer that
    applies to one person, and where it comes from (`:user`, `:tenant`,
    `:event`)
  - `put/2` and `clear/2` — set or remove one row (`clear` is "reset to the
    default")
  """

  @behaviour AshDispatch.UserPreference

  alias AshDispatch.{Config, Context, Tenancy, UserPreference}

  require Ash.Query

  @impl true
  def user_allows?(user_id, event_id, transport, opts) do
    tenant = Context.tenant_key(Keyword.get(opts, :tenant))
    category = category_key(Keyword.get(opts, :category))
    key = scope_key(tenant, event_id, category)

    rows =
      case UserPreference.scope_get(key) do
        %{users: users, rows: rows} = cached ->
          if MapSet.member?(users, user_id) do
            rows
          else
            cached |> load_more(key, tenant, event_id, category, [user_id]) |> Map.fetch!(:rows)
          end

        nil ->
          %{users: MapSet.new(), rows: []}
          |> load_more(key, tenant, event_id, category, [user_id])
          |> Map.fetch!(:rows)
      end

    {enabled, _source} =
      resolve(
        rows,
        user_id,
        event_id,
        category,
        transport,
        Keyword.get(opts, :event_default, true)
      )

    enabled
  end

  @impl true
  def prefetch(user_ids, opts) do
    tenant = Context.tenant_key(Keyword.get(opts, :tenant))
    category = category_key(Keyword.get(opts, :category))
    event_id = Keyword.get(opts, :event_id)
    key = scope_key(tenant, event_id, category)

    cached = UserPreference.scope_get(key) || %{users: MapSet.new(), rows: []}
    missing = Enum.reject(user_ids, &MapSet.member?(cached.users, &1))

    if missing != [], do: load_more(cached, key, tenant, event_id, category, missing)
    :ok
  end

  @doc """
  The answer for one person, one event, one transport, from a set of rows,
  and where it came from: `{enabled?, :user | :tenant | :event}`.

  Pure — exposed so a settings screen and the send path cannot disagree.
  """
  @spec resolve([map()], any(), String.t() | nil, String.t() | nil, atom(), boolean()) ::
          {boolean(), :user | :tenant | :event}
  def resolve(rows, user_id, event_id, category, transport, event_default \\ true) do
    category = category_key(category)
    rows = Enum.filter(rows, &(&1.transport == transport))

    candidates = [
      {:user, &(&1.user_id == user_id and not is_nil(user_id) and &1.event_id == event_id)},
      {:user,
       &(&1.user_id == user_id and not is_nil(user_id) and is_nil(&1.event_id) and
           not is_nil(category) and &1.category == category)},
      {:tenant, &(is_nil(&1.user_id) and &1.event_id == event_id)},
      {:tenant,
       &(is_nil(&1.user_id) and is_nil(&1.event_id) and not is_nil(category) and
           &1.category == category)}
    ]

    Enum.find_value(candidates, {event_default != false, :event}, fn {source, match?} ->
      case Enum.find(rows, match?) do
        nil -> nil
        row -> {row.enabled, source}
      end
    end)
  end

  @doc """
  The events a person can switch on and off, for a settings screen.

  One map per event in the registry:

      %{
        id: "meetings.invited",
        category: "meetings",       # nil when the event declares none
        transports: [:email, :in_app],
        default: %{email: true, in_app: true},   # the event's own default
        configurable: true           # false: mandatory, shown locked
      }

  Only channels to preference-gated audiences count
  (`AshDispatch.Config.preference_gated_audiences/0`): a delivery to an
  ungated audience is never asked about, so offering a switch for it would
  be a lie. Pass `configurable_only: true` to leave the mandatory events out.
  """
  @spec configurable_events(keyword()) :: [map()]
  def configurable_events(opts \\ []) do
    otp_app = Keyword.get(opts, :otp_app) || Config.otp_app()
    gated = Config.preference_gated_audiences()

    events = if otp_app, do: AshDispatch.EventRegistry.all_events(otp_app), else: []

    events
    |> Enum.map(fn event ->
      transports =
        (event.channels || [])
        |> Enum.filter(&(channel_field(&1, :audience) in gated))
        |> Enum.map(&channel_field(&1, :transport))
        |> Enum.uniq()

      %{
        id: event.event_id,
        category: category_key(event_category(event)),
        transports: transports,
        default: Map.new(transports, &{&1, UserPreference.event_default(event, &1)}),
        configurable: UserPreference.user_configurable?(event)
      }
    end)
    |> Enum.reject(&(&1.transports == []))
    |> then(fn events ->
      if Keyword.get(opts, :configurable_only, false),
        do: Enum.filter(events, & &1.configurable),
        else: events
    end)
    |> Enum.sort_by(&{&1.category || "", &1.id})
  end

  @doc """
  Every event × transport of `configurable_events/1` with the answer that
  applies to `user_id` in `tenant` — one query.

      %{
        event_id: "meetings.invited",
        category: "meetings",
        transport: :email,
        enabled: false,
        source: :user,          # :user | :tenant | :event
        tenant_default: true,   # what "reset" goes back to
        configurable: true
      }

  With `user_id` `nil` it is the tenant's own screen: `source` is then
  `:tenant` or `:event` and `tenant_default` is the event's default.
  """
  @spec settings(any(), term(), keyword()) :: [map()]
  def settings(user_id, tenant, opts \\ []) do
    tenant = Context.tenant_key(tenant)
    events = configurable_events(opts)
    rows = read_all(tenant, user_id)

    for event <- events, transport <- event.transports do
      default = Map.fetch!(event.default, transport)

      {enabled, source} =
        if event.configurable,
          do: resolve(rows, user_id, event.id, event.category, transport, default),
          else: {true, :event}

      {tenant_default, _} = resolve(rows, nil, event.id, event.category, transport, default)

      %{
        event_id: event.id,
        category: event.category,
        transport: transport,
        enabled: enabled,
        source: source,
        tenant_default: if(event.configurable, do: tenant_default, else: true),
        configurable: event.configurable
      }
    end
  end

  @doc """
  Sets one row. `scope` is a map or keyword with `:tenant`, `:user_id`
  (`nil` for the tenant default), `:transport` and one of `:event_id` /
  `:category`.

  Options are passed to `Ash.create/2` — `actor:` (the policies decide), or
  `authorize?: false` once the app has checked.
  """
  @spec put(map() | keyword(), boolean(), keyword()) :: {:ok, struct()} | {:error, term()}
  def put(scope, enabled, opts \\ []) do
    attrs =
      scope
      |> scope_attrs()
      |> Map.put(:enabled, enabled == true)

    action_opts = Keyword.take(opts, [:actor, :authorize?])

    # An existing row is updated, so the answer does not depend on the data
    # layer's upsert treating nil keys as equal; `:set` upserts as well,
    # which covers two writers racing on Postgres.
    case find_rows(attrs, action_opts) do
      {:ok, [row | _]} ->
        row
        |> Ash.Changeset.for_update(:update, %{enabled: attrs.enabled}, action_opts)
        |> Tenancy.set(attrs.tenant)
        |> Ash.update(action_opts)

      {:ok, []} ->
        resource()
        |> Ash.Changeset.for_create(:set, attrs, action_opts)
        |> Tenancy.set(attrs.tenant)
        |> Ash.create(action_opts)

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Removes one row, so the next level's answer applies again ("reset").
  Same `scope` and options as `put/3`. Removing a row that does not exist
  is `:ok`.
  """
  @spec clear(map() | keyword(), keyword()) :: :ok | {:error, term()}
  def clear(scope, opts \\ []) do
    attrs = scope_attrs(scope)

    with {:ok, rows} <- find_rows(attrs, Keyword.take(opts, [:actor, :authorize?])) do
      Enum.reduce_while(rows, :ok, fn row, :ok ->
        case Ash.destroy(
               row,
               Keyword.take(opts, [:actor, :authorize?]) ++ tenant_opts(attrs.tenant)
             ) do
          :ok -> {:cont, :ok}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end
  end

  # ── private ─────────────────────────────────────────────────────────

  defp find_rows(attrs, opts) do
    resource()
    |> Ash.Query.filter(transport == ^attrs.transport)
    |> filter_eq(:tenant, attrs.tenant)
    |> filter_eq(:user_id, attrs.user_id)
    |> filter_eq(:event_id, attrs[:event_id])
    |> filter_eq(:category, attrs[:category])
    |> Ash.read(opts ++ tenant_opts(attrs.tenant))
  end

  # The scope's tenant is both the `tenant` COLUMN and, for a preference
  # resource built with `multitenancy: :context`, the schema the row lives in.
  # Writing and filtering both means one code path for the two kinds of host:
  # for a per-tenant resource the column is a redundant copy of what the schema
  # already says, and for a public one it is the only thing that says it.
  defp tenant_opts(tenant), do: Tenancy.opts(resource(), tenant)

  # Registry channels are the DSL's keyword lists; resolved ones are structs.
  defp channel_field(channel, key) when is_list(channel), do: Keyword.get(channel, key)
  defp channel_field(channel, key) when is_map(channel), do: Map.get(channel, key)

  defp resource do
    Config.preference_resource() ||
      raise ArgumentError, """
      AshDispatch.UserPreference.Resource needs a preference resource:

          config :ash_dispatch,
            preference_resource: MyApp.Notifications.Preference

      (a resource that uses AshDispatch.Resources.Preference.Base)
      """
  end

  defp scope_key(tenant, event_id, category),
    do: {__MODULE__, tenant, event_id, category}

  defp load_more(cached, key, tenant, event_id, category, user_ids) do
    ids = user_ids |> Enum.reject(&is_nil/1) |> Enum.uniq()
    known = MapSet.union(cached.users, MapSet.new(user_ids))

    rows =
      resource()
      |> Ash.Query.for_read(
        :for_scope,
        %{tenant: tenant, event_id: event_id, category: category, user_ids: ids},
        authorize?: false
      )
      |> Ash.read!([authorize?: false] ++ tenant_opts(tenant))

    # Tenant defaults come back with every read; keep one copy of each row.
    merged = %{users: known, rows: Enum.uniq_by(cached.rows ++ rows, & &1.id)}
    UserPreference.scope_put(key, merged)
    merged
  end

  defp read_all(tenant, user_id) do
    resource()
    |> Ash.Query.new()
    |> filter_eq(:tenant, tenant)
    |> then(fn query ->
      if is_nil(user_id),
        do: Ash.Query.filter(query, is_nil(user_id)),
        else: Ash.Query.filter(query, is_nil(user_id) or user_id == ^user_id)
    end)
    |> Ash.read!([authorize?: false] ++ tenant_opts(tenant))
  end

  defp filter_eq(query, field, nil), do: Ash.Query.filter(query, is_nil(^Ash.Expr.ref(field)))

  defp filter_eq(query, field, value),
    do: Ash.Query.filter(query, ^Ash.Expr.ref(field) == ^value)

  defp scope_attrs(scope) do
    scope = Map.new(scope)

    %{
      tenant: Context.tenant_key(Map.get(scope, :tenant)),
      user_id: Map.get(scope, :user_id),
      transport: Map.fetch!(scope, :transport)
    }
    |> then(fn attrs ->
      case scope do
        %{event_id: event_id} when not is_nil(event_id) -> Map.put(attrs, :event_id, event_id)
        %{category: category} -> Map.put(attrs, :category, category_key(category))
        _ -> raise ArgumentError, "a preference scope needs :event_id or :category"
      end
    end)
  end

  defp event_category(event) do
    case event[:metadata] do
      metadata when is_list(metadata) or is_map(metadata) -> metadata[:category]
      _ -> nil
    end
    |> case do
      nil -> module_category(event[:module])
      category -> category
    end
  end

  defp module_category(nil), do: nil

  defp module_category(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :category, 1),
      do: module.category(%Context{event_id: nil, data: %{}})
  rescue
    _ -> nil
  end

  defp category_key(nil), do: nil
  defp category_key(category) when is_binary(category), do: category
  defp category_key(category), do: to_string(category)
end
