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

  ## Security

  Only check preferences for `:user` audience events. Admin/team/system
  notifications typically shouldn't be user-configurable.
  """

  alias AshDispatch.{Context, Channel}

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

  ## Returns

  - `true` - User allows or no user in context or preferences not configured
  - `false` - User has opted out
  """
  @spec allows?(Context.t(), Channel.t(), keyword()) :: boolean()
  def allows?(context, channel, event_config \\ []) do
    # Skip preference check for non-user audiences
    if channel.audience != :user do
      true
    else
      # Get user_id from context
      user_id = get_user_id(context)

      if is_nil(user_id) do
        # No user, can't check preferences
        true
      else
        # Get category from event metadata
        metadata = event_config[:metadata] || []
        category = metadata[:category]

        # Build options
        opts = [
          category: category,
          audience: channel.audience,
          event_id: context.event_id
        ]

        # Call configured checker
        checker = get_checker()
        checker.user_allows?(user_id, context.event_id, channel.transport, opts)
      end
    end
  end

  # Private helpers

  defp get_user_id(%Context{user: nil}), do: nil
  defp get_user_id(%Context{user: %{id: id}}), do: id
  defp get_user_id(%Context{user: user}) when is_binary(user), do: user
  defp get_user_id(%Context{user: user}) when is_integer(user), do: user
  defp get_user_id(_), do: nil

  defp get_checker do
    Application.get_env(:ash_dispatch, :user_preference, __MODULE__.Default)
  end
end
