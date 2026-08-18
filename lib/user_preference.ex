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
        category: event_category(event_config),
        audience: channel.audience
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
  - the configured checker says the user allows it.

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
        category: event_category(event_config),
        audience: channel.audience
      )
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
        event_id: event_id
      ]
      |> Keyword.merge(Keyword.drop(opts, [:category, :audience, :event_id]))

    get_checker().user_allows?(user_id, event_id, transport, checker_opts)
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
