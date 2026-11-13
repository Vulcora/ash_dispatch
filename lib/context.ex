defmodule AshDispatch.Context do
  @moduledoc """
  Event context passed to all event callbacks and transports.

  The context contains:
  - Event data (resources, user, etc.)
  - Metadata (event_id, source, timestamp)
  - Configuration (locale, base_url)
  - Computed values from enrichment

  ## Example

      %Context{
        event_id: "orders.created",
        data: %{
          order: %ProductOrder{...},
          user: %User{...}
        },
        user: %User{...},
        locale: "sv",
        base_url: "https://myapp.com",
        now: ~U[2025-01-15 10:00:00Z],
        resource_key: :order
      }
  """

  @type t :: %__MODULE__{
          event_id: String.t(),
          data: map(),
          variables: map(),
          resource_key: atom() | nil,
          priority: :urgent | :standard | :informational,
          locale: String.t(),
          user: struct() | nil,
          actor: struct() | map() | nil,
          tenant: term() | nil,
          source: String.t() | nil,
          base_url: String.t(),
          now: DateTime.t(),
          metadata: map(),
          opts: map()
        }

  alias AshDispatch.Config

  defstruct [
    :event_id,
    :data,
    :resource_key,
    :user,
    :actor,
    :tenant,
    :source,
    :locale,
    priority: :standard,
    base_url: "",
    now: nil,
    metadata: %{},
    opts: %{},
    variables: %{}
  ]

  @doc """
  Creates a new context.

  ## Options

  - `:event_id` - Event identifier
  - `:data` - Event data map (resources, domain objects)
  - `:variables` - Variables map (tokens, simple values, template data)
  - `:resource_key` - Hint for nested user lookup
  - `:locale` - Locale for i18n
  - `:user` - Actor/user triggering the event
  - `:actor` - Who caused the event: the action's actor for an
    action-triggered event, the `:actor` option of `Dispatcher.dispatch/4`
    for a manual one, `nil` for a system event. Unlike `:user`, never looked
    up in `data`. Since 0.8.8
  - `:tenant` - The tenant the event happened in: the action's tenant, or the
    `:tenant` option of `Dispatcher.dispatch/4`. Handed to the preference
    checker as `opts[:tenant]` (since 0.8.8) and stored on in-app
    notifications (since 0.9.0); see `tenant_key/1`.
  - `:base_url` - Base URL for link building
  - `:metadata` - Additional metadata
  - `:opts` - Additional options

  ## Example

      Context.new(
        event_id: "orders.created",
        data: %{order: order, user: user},
        variables: %{confirmation_token: token},
        user: user,
        locale: "sv"
      )
  """
  def new(opts) do
    %__MODULE__{
      event_id: Keyword.fetch!(opts, :event_id),
      data: atomize_keys(Keyword.get(opts, :data, %{})),
      variables: atomize_keys(Keyword.get(opts, :variables, %{})),
      resource_key: Keyword.get(opts, :resource_key),
      locale: Keyword.get(opts, :locale, Config.default_locale()),
      user: Keyword.get(opts, :user),
      actor: Keyword.get(opts, :actor),
      tenant: Keyword.get(opts, :tenant),
      source: Keyword.get(opts, :source),
      base_url: Keyword.get(opts, :base_url, get_default_base_url()),
      now: Keyword.get(opts, :now, DateTime.utc_now()),
      metadata: Keyword.get(opts, :metadata, %{}),
      opts: Map.new(opts)
    }
  end

  @doc """
  Recursively atomizes string keys in maps.

  Skips structs to preserve Ash resources.

  ## Examples

      iex> Context.atomize_keys(%{"user" => %{"email" => "test@example.com"}})
      %{user: %{email: "test@example.com"}}

      iex> Context.atomize_keys(%User{email: "test@example.com"})
      %User{email: "test@example.com"}
  """
  def atomize_keys(%{__struct__: _} = struct), do: struct

  def atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if is_binary(k), do: String.to_atom(k), else: k
      {key, atomize_keys(v)}
    end)
  end

  def atomize_keys(list) when is_list(list), do: Enum.map(list, &atomize_keys/1)
  def atomize_keys(value), do: value

  @doc """
  Enriches context with additional data.

  Used by Dispatcher to auto-populate common fields like admins.

  ## Example

      context
      |> Context.enrich(:admins, list_of_admins)
      |> Context.enrich(:metadata, %{custom: "value"})
  """
  def enrich(%__MODULE__{} = context, key, value) when is_atom(key) do
    %{context | data: Map.put(context.data, key, value)}
  end

  def enrich(%__MODULE__{} = context, map) when is_map(map) do
    %{context | data: Map.merge(context.data, atomize_keys(map))}
  end

  @doc """
  Merges metadata into context.
  """
  def merge_metadata(%__MODULE__{} = context, metadata) when is_map(metadata) do
    %{context | metadata: Map.merge(context.metadata, metadata)}
  end

  @doc """
  Gets all assigns for template rendering by merging data and variables.

  Variables take precedence over data in case of key conflicts.

  ## Example

      context = %Context{
        data: %{user: user, order: order},
        variables: %{confirmation_token: "abc123"}
      }

      Context.template_assigns(context)
      # => %{user: user, order: order, confirmation_token: "abc123"}
  """
  def template_assigns(%__MODULE__{} = context) do
    Map.merge(context.data, context.variables)
  end

  @doc """
  The tenant as the string ash_dispatch stores in the `tenant` **column**.

  A tenant reaches the library in whatever shape the app uses for Ash: a
  string, an integer, or a record (an organisation struct). Notification,
  preference and receipt rows store it as a string, so every shape is reduced
  to one: a binary as it is, a record by its `:id`, anything else through
  `to_string/1`. `nil` stays `nil` — an app without tenancy.

  This is the column, not a schema name. Which schema a tenant's rows live in
  is `Ash.ToTenant`'s answer, and the library asks it through
  `AshDispatch.Tenancy.prefix/2`. For a struct tenant the two differ, by
  design: `Ash.ToTenant`'s own example turns `%{id: id}` into `"org_" <> id`.

  ## Examples

      iex> AshDispatch.Context.tenant_key(nil)
      nil

      iex> AshDispatch.Context.tenant_key("org_1")
      "org_1"

      iex> AshDispatch.Context.tenant_key(42)
      "42"

      iex> AshDispatch.Context.tenant_key(%{id: "0190a"})
      "0190a"
  """
  @spec tenant_key(term()) :: String.t() | nil
  def tenant_key(nil), do: nil
  def tenant_key(tenant) when is_binary(tenant), do: tenant
  def tenant_key(%{id: id}), do: tenant_key(id)
  def tenant_key(tenant) when is_atom(tenant) or is_number(tenant), do: to_string(tenant)

  # A term that is neither a string, a number, an atom nor something with an
  # `:id` used to fall into `to_string/1`, which for a struct raises
  # `Protocol.UndefinedError` from wherever the library happened to be — in
  # the middle of building an Oban job's args, for one. Say what is wrong
  # instead, and name the two ways to fix it.
  def tenant_key(tenant) do
    if String.Chars.impl_for(tenant) do
      to_string(tenant)
    else
      raise AshDispatch.Tenancy.UnsupportedTenantError, tenant: tenant
    end
  end

  # Private helpers

  defp get_default_base_url do
    # Priority order:
    # 1. Configured endpoint module (calls Endpoint.url())
    # 2. PHX_HOST environment variable
    # 3. Explicit base_url config (deprecated)
    # 4. Fallback to localhost
    cond do
      endpoint = Config.endpoint() ->
        endpoint.url()

      host = System.get_env("PHX_HOST") ->
        scheme = System.get_env("PHX_SCHEME", "https")
        port = System.get_env("PHX_PORT", "443")

        case {scheme, port} do
          {"https", "443"} -> "#{scheme}://#{host}"
          {"http", "80"} -> "#{scheme}://#{host}"
          _ -> "#{scheme}://#{host}:#{port}"
        end

      base_url = Config.base_url() ->
        base_url

      true ->
        "http://localhost:4000"
    end
  end
end
