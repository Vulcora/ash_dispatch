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
          locale: String.t(),
          user: struct() | nil,
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
    :source,
    locale: "en",
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
      locale: Keyword.get(opts, :locale, "en"),
      user: Keyword.get(opts, :user),
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
