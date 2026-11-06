defmodule AshDispatch.UserPreference do
  @moduledoc """
  Behaviour for checking user notification preferences.

  Allows consuming apps to control which notifications users receive based on
  their preferences. Users can opt out of specific event categories, transports,
  or both.

  ## Configuration

  Configure your preference checker in config:

      # config/config.exs
      config :ash_dispatch,
        user_preference: MyApp.NotificationPreferences

  ## Implementing the Behaviour

      defmodule MyApp.NotificationPreferences do
        @behaviour AshDispatch.UserPreference

        @impl true
        def user_allows?(user_id, event_id, transport, opts) do
          # Query your preference system
          case Ash.get(UserPreference, user_id) do
            {:ok, prefs} ->
              category = opts[:category]

              # Check if user disabled this category
              if category in prefs.disabled_categories do
                false
              # Check if user disabled this transport
              else if transport in prefs.disabled_transports do
                false
              else
                true
              end

            _ ->
              true  # Allow if no preferences found
          end
        end
      end

  ## Usage in Events

  Events should specify their category for preference filtering:

      dispatch do
        event :promotional_offer,
          trigger_on: :create,
          channels: [[transport: :email, audience: :user]],
          metadata: [
            category: :marketing  # Users can opt out of :marketing
          ]
      end

  ## Preference Granularity

  Users can control notifications at three levels:

  1. **By Category** - Opt out of entire categories (e.g., :marketing, :billing)
  2. **By Transport** - Opt out of specific transports (e.g., no :email, yes :in_app)
  3. **Both** - Opt out of category+transport combinations

  ## Default Behavior

  If no preference checker is configured, all notifications are sent.
  This ensures AshDispatch works out-of-the-box without requiring preference setup.

  ## Which deliveries are gated

  Only the `:user` audience is preference-gated by default. Admin/team/system
  notifications typically shouldn't be user-configurable — an operator must
  not be able to silence an operational alert by unticking a marketing box.

  Apps that fan a marketing-style event out to an audience of their own can
  opt that audience in:

      config :ash_dispatch,
        preference_gated_audiences: [:user, :customers]

  See `AshDispatch.Config.preference_gated_audiences/0`.

  ## Per-recipient evaluation

  The gate runs **per receipt**, i.e. once per recipient, via
  `allows_receipt?/4` — one event fanned out to N recipients produces N
  independent verdicts. (Before 0.6.4 the transports asked about the
  *context* user and applied that single verdict to every recipient.)
  """

  alias AshDispatch.{Channel, Config, Context}

  @doc """
  Checks if a user allows a specific notification.

  ## Parameters

  - `user_id` - User identifier (can be any type)
  - `event_id` - Event identifier string (e.g., "orders.created")
  - `transport` - Transport atom (e.g., :email, :in_app)
  - `opts` - Options keyword list with:
    - `:category` - Event category atom (e.g., :billing, :marketing)
    - `:audience` - Channel audience (e.g., :user, :admin)
    - `:event_id` - the event id again, for checkers that pass opts on
    - `:tenant` - the tenant the event happened in (`context.tenant`: the
      action's tenant, or `Dispatcher.dispatch/4`'s `:tenant`), or `nil`.
      Since 0.8.8
    - `:recipient` - the resolved recipient this receipt is for (a user
      struct or a recipient map), or `nil` outside the send path. Since 0.8.8
    - `:event_default` - the event's own default for this transport
      (`metadata: [preference_default: ...]`, else `true`): what to answer
      when the person and the tenant have said nothing. Since 0.9.0

  ## Returns

  - `true` - User allows this notification
  - `false` - User has opted out

  ## Examples

      # User allows order emails
      iex> user_allows?(123, "orders.created", :email, category: :transactional)
      true

      # User opted out of marketing emails
      iex> user_allows?(123, "promo.new", :email, category: :marketing)
      false

      # User allows marketing in-app (only opted out of marketing emails)
      iex> user_allows?(123, "promo.new", :in_app, category: :marketing)
      true
  """
  @callback user_allows?(
              user_id :: any(),
              event_id :: String.t(),
              transport :: atom(),
              opts :: keyword()
            ) :: boolean()

  @doc """
  Loads what `c:user_allows?/4` will need for a batch of recipients, before
  it is asked about each of them. Optional.

  The dispatcher calls it once per channel with every recipient's user id
  (`nil` for recipients without one) and the same opts `c:user_allows?/4`
  gets, minus `:recipient`. A checker that reads a database keeps the result
  for the dispatch — `with_dispatch_scope/1` and `scope_get/1` /
  `scope_put/2` are the place — so a fan-out to N recipients costs one query
  instead of N. Return value is ignored.
  """
  @callback prefetch(user_ids :: [any()], opts :: keyword()) :: any()

  @optional_callbacks [prefetch: 2]

  @scope_key {__MODULE__, :dispatch_scope}

  @doc """
  Checks if user allows notification based on context and channel.

  This is a convenience wrapper around the callback that extracts relevant
  data from Context and Channel structs.

  **Prefer `allows_receipt?/4` in delivery paths.** This function reads the
  user from the *context*, which is the event's subject — not necessarily
  the recipient being delivered to. On a fan-out (one event, N receipts)
  every recipient gets the context user's verdict. `allows_receipt?/4`
  asks about the receipt's own user, which is what the transports do since
  0.6.4.

  ## Returns

  - `true` - User allows or no user in context or preferences not configured
  - `false` - User has opted out
  """
  @spec allows?(Context.t(), Channel.t(), keyword()) :: boolean()
  def allows?(context, channel, event_config \\ []) do
    # Skip preference check for audiences that aren't preference-gated
    if not gated_audience?(channel.audience) do
      true
    else
      allows_user?(
        get_user_id(context),
        context.event_id,
        channel.transport,
        gate_opts(context, channel, event_config)
      )
    end
  end

  @doc """
  Checks whether the recipient of a **receipt** allows this delivery.

  This is the gate the `:email` and `:in_app` transports run before
  delivering. Unlike `allows?/3` it reads `receipt.user_id` — the actual
  recipient of this one receipt — so a fan-out to N recipients evaluates N
  independent preference verdicts instead of applying the context user's
  verdict to everyone.

  Returns `true` (deliver) when:

  - the channel's audience is not preference-gated
    (see `AshDispatch.Config.preference_gated_audiences/0`, default `[:user]`), or
  - the receipt has no `user_id` — external recipients (a plain email
    address, a webhook target) have no preferences to consult, or
  - the event is mandatory — `metadata: [user_configurable: false]`, or
    `user_configurable? false` in an event module's DSL — and is never
    gated, whatever the checker would say, or
  - the configured checker says the user allows it.

  The checker's opts carry `:category`, `:audience`, `:event_id`, `:tenant`
  (`context.tenant`) and `:recipient` (the resolved recipient of this
  receipt).

  ## Examples

      iex> AshDispatch.UserPreference.allows_receipt?(receipt, context, channel, event_config)
      true
  """
  @spec allows_receipt?(map(), Context.t(), Channel.t(), keyword()) :: boolean()
  def allows_receipt?(receipt, context, channel, event_config \\ []) do
    if not gated_audience?(channel.audience) do
      true
    else
      allows_user?(
        receipt_user_id(receipt),
        context.event_id,
        channel.transport,
        gate_opts(context, channel, event_config)
        |> Keyword.put(:recipient, context_recipient(context))
      )
    end
  end

  @doc false
  # Called by the dispatcher once per channel, before the receipts are
  # created: hands the batch of user ids to the checker's `prefetch/2`, when
  # it has one and the channel is gated.
  @spec prefetch([any()], Context.t(), Channel.t(), keyword() | map()) :: :ok
  def prefetch(user_ids, context, channel, event_config) do
    checker = get_checker()
    opts = gate_opts(context, channel, event_config)

    if gated_audience?(channel.audience) and not mandatory?(opts) and
         Code.ensure_loaded?(checker) and function_exported?(checker, :prefetch, 2) do
      ids = user_ids |> Enum.reject(&is_nil/1) |> Enum.uniq()
      if ids != [], do: checker.prefetch(ids, opts)
    end

    :ok
  rescue
    # Prefetching is an optimisation: when it fails the checker is asked
    # per receipt, as without it.
    error ->
      require Logger
      Logger.warning("Preference prefetch failed: #{Exception.message(error)}")
      :ok
  end

  @doc """
  Runs `fun` inside a dispatch scope: a per-process store a checker can use
  to keep what it read for the rest of one dispatch (`scope_get/1`,
  `scope_put/2`). The dispatcher opens one around every dispatch. Nested
  calls share the outer scope; the store is gone when the outermost returns.
  """
  @spec with_dispatch_scope((-> result)) :: result when result: var
  def with_dispatch_scope(fun) when is_function(fun, 0) do
    case Process.get(@scope_key) do
      nil ->
        Process.put(@scope_key, %{})

        try do
          fun.()
        after
          Process.delete(@scope_key)
        end

      _open ->
        fun.()
    end
  end

  @doc "Reads `key` from the current dispatch scope; `nil` outside one or when unset."
  @spec scope_get(term()) :: term()
  def scope_get(key) do
    case Process.get(@scope_key) do
      %{} = scope -> Map.get(scope, key)
      _ -> nil
    end
  end

  @doc "Stores `value` under `key` in the current dispatch scope. Outside a scope it does nothing."
  @spec scope_put(term(), term()) :: :ok
  def scope_put(key, value) do
    case Process.get(@scope_key) do
      %{} = scope -> Process.put(@scope_key, Map.put(scope, key, value))
      _ -> nil
    end

    :ok
  end

  @doc """
  Whether an event can be switched off by the people who receive it.

  `false` when its metadata says `user_configurable: false` (or
  `user_configurable?: false`), or its event module's DSL sets
  `user_configurable? false`. A mandatory event is never gated by
  preferences and is not offered in a settings screen.
  """
  @spec user_configurable?(String.t() | map() | keyword()) :: boolean()
  def user_configurable?(event_id) when is_binary(event_id) do
    case AshDispatch.EventRegistry.find_event(event_id) do
      {:ok, event} -> user_configurable?(event)
      {:error, _} -> module_configurable?(event_module(event_id), event_id)
    end
  end

  def user_configurable?(event_config) when is_list(event_config) or is_map(event_config) do
    metadata = metadata_of(event_config)

    cond do
      access(metadata, :user_configurable) == false -> false
      access(metadata, :user_configurable?) == false -> false
      true -> module_configurable?(access(event_config, :module), access(event_config, :event_id))
    end
  end

  @doc """
  The event's own default for `transport`: what a recipient gets when
  neither they nor their tenant has said anything.

  Read from `metadata: [preference_default: ...]` — a boolean for every
  transport, or a keyword list per transport (`[email: false, in_app: true]`,
  unlisted transports `true`). Without it, `true`.
  """
  @spec event_default(keyword() | map(), atom()) :: boolean()
  def event_default(event_config, transport) do
    case access(metadata_of(event_config), :preference_default) do
      value when is_boolean(value) ->
        value

      per_transport when is_list(per_transport) or is_map(per_transport) ->
        access(per_transport, transport) != false

      _ ->
        true
    end
  end

  @doc """
  The pure preference predicate: may this user receive this event on this
  transport?

  It resolves the configured checker (`config :ash_dispatch,
  user_preference: MyApp.Preferences`, defaulting to
  `AshDispatch.UserPreference.Default`, which allows everything) and calls
  its `c:user_allows?/4` callback. It reads nothing from a context, a
  channel or a receipt, so it can be called from anywhere a `user_id` is
  known — a recipient count in an admin screen, a "would this user get
  it?" check, a digest opt-out — and is guaranteed to agree with the
  answer the send path will reach.

  Returns `true` when `user_id` is `nil`: a recipient without a user
  account has no preferences, and the library's default is to deliver.

  ## Parameters

  - `user_id` - the recipient's user id (any type your checker accepts), or `nil`
  - `event_id` - event identifier string, e.g. `"orders.created"`
  - `transport` - transport atom, e.g. `:email`, `:in_app`
  - `opts` - passed through to the checker, augmented with `:event_id`:
    - `:category` - the event's category atom (e.g. `:marketing`)
    - `:audience` - the channel audience the check is running for
    - `:tenant` - the tenant, when known (`nil` otherwise)
    - `:recipient` - the recipient, when known (`nil` otherwise)

  ## Examples

      # Does this customer still want marketing email?
      iex> AshDispatch.UserPreference.allows_user?(user.id, "mailing.sent", :email, category: :marketing)
      false

      # No user id (external recipient) — nothing to consult, deliver
      iex> AshDispatch.UserPreference.allows_user?(nil, "orders.created", :email, [])
      true
  """
  @spec allows_user?(any(), String.t(), atom(), keyword()) :: boolean()
  def allows_user?(user_id, event_id, transport, opts \\ [])

  def allows_user?(nil, _event_id, _transport, _opts), do: true

  def allows_user?(user_id, event_id, transport, opts) do
    checker_opts =
      [
        category: Keyword.get(opts, :category),
        audience: Keyword.get(opts, :audience),
        event_id: event_id,
        tenant: Keyword.get(opts, :tenant),
        recipient: Keyword.get(opts, :recipient),
        event_default: Keyword.get(opts, :event_default, true)
      ]
      |> Keyword.merge(
        Keyword.drop(opts, [
          :category,
          :audience,
          :event_id,
          :tenant,
          :recipient,
          :event_default,
          :user_configurable
        ])
      )

    # A mandatory event is never gated. Callers on the send path say so in
    # `:user_configurable`; anyone else gets it looked up.
    configurable? =
      case Keyword.fetch(opts, :user_configurable) do
        {:ok, value} -> value != false
        :error -> user_configurable?(event_id)
      end

    if configurable? do
      get_checker().user_allows?(user_id, event_id, transport, checker_opts)
    else
      true
    end
  end

  @doc """
  Whether deliveries to `audience` are gated by user preferences.

  Reads `AshDispatch.Config.preference_gated_audiences/0`, which defaults
  to `[:user]` — the only audience any release before 0.6.4 ever gated.
  """
  @spec gated_audience?(atom()) :: boolean()
  def gated_audience?(audience) do
    audience in Config.preference_gated_audiences()
  end

  # Private helpers

  defp receipt_user_id(%{user_id: user_id}), do: user_id
  defp receipt_user_id(_), do: nil

  defp gate_opts(context, channel, event_config) do
    [
      category: event_category(event_config),
      audience: channel.audience,
      tenant: Map.get(context, :tenant),
      event_id: Map.get(context, :event_id),
      user_configurable: user_configurable?(with_event_id(event_config, context)),
      event_default: event_default(event_config, channel.transport)
    ]
  end

  defp mandatory?(opts), do: Keyword.get(opts, :user_configurable) == false

  defp with_event_id(event_config, context) when is_list(event_config) do
    Keyword.put_new(event_config, :event_id, Map.get(context, :event_id))
  end

  defp with_event_id(event_config, context) when is_map(event_config) do
    Map.put_new(event_config, :event_id, Map.get(context, :event_id))
  end

  defp with_event_id(_event_config, context), do: [event_id: Map.get(context, :event_id)]

  defp context_recipient(%{opts: %{ash_dispatch_recipient: recipient}}), do: recipient
  defp context_recipient(_), do: nil

  defp metadata_of(event_config) do
    case access(event_config, :metadata) do
      metadata when is_list(metadata) or is_map(metadata) -> metadata
      _ -> []
    end
  end

  # Access that never raises: keyword lists, maps, anything else is nil.
  defp access(data, key) when is_map(data), do: Map.get(data, key)

  defp access(data, key) when is_list(data) do
    if Keyword.keyword?(data), do: Keyword.get(data, key)
  end

  defp access(_data, _key), do: nil

  defp event_module(nil), do: nil

  defp event_module(event_id) do
    case AshDispatch.EventResolver.find_module(event_id) do
      {:ok, module} -> module
      _ -> nil
    end
  end

  # An event module's `user_configurable?/1` (the DSL option; `true` when
  # unset). Only an explicit `false` makes the event mandatory.
  defp module_configurable?(nil, _event_id), do: true

  defp module_configurable?(module, event_id) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :user_configurable?, 1) do
      module.user_configurable?(%Context{event_id: event_id, data: %{}}) != false
    else
      true
    end
  rescue
    _ -> true
  end

  defp module_configurable?(_module, _event_id), do: true

  # `event_config` is Access-compatible (keyword list or map) and its
  # `:metadata` is likewise either shape.
  defp event_category(event_config) when is_list(event_config) or is_map(event_config) do
    case event_config[:metadata] do
      nil -> nil
      metadata when is_list(metadata) or is_map(metadata) -> metadata[:category]
      _other -> nil
    end
  rescue
    # A non-Access event_config must never take down a delivery.
    _ -> nil
  end

  defp event_category(_), do: nil

  defp get_user_id(%Context{user: nil}), do: nil
  defp get_user_id(%Context{user: %{id: id}}), do: id
  defp get_user_id(%Context{user: user}) when is_binary(user), do: user
  defp get_user_id(%Context{user: user}) when is_integer(user), do: user
  defp get_user_id(_), do: nil

  defp get_checker do
    Config.user_preference()
  end
end
