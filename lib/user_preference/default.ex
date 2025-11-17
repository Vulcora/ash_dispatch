defmodule AshDispatch.UserPreference.Default do
  @moduledoc """
  Default user preference checker that allows all notifications.

  This is used when no custom preference checker is configured. It always
  returns `true`, meaning all notifications are sent.

  ## Why Default to Allow?

  AshDispatch should work out-of-the-box without requiring preference setup.
  Apps can add preference checking later when they're ready.

  ## Configuring a Custom Checker

  To enable user preference checking, configure your own implementation:

      # config/config.exs
      config :ash_dispatch,
        user_preference: MyApp.NotificationPreferences

  Then implement the behaviour:

      defmodule MyApp.NotificationPreferences do
        @behaviour AshDispatch.UserPreference

        @impl true
        def user_allows?(user_id, _event_id, _transport, opts) do
          # Your preference logic here
          category = opts[:category]

          # Example: Check database
          case Ash.get(UserPreference, user_id) do
            {:ok, prefs} -> category not in prefs.disabled_categories
            _ -> true
          end
        end
      end

  See `AshDispatch.UserPreference` for complete documentation.
  """

  @behaviour AshDispatch.UserPreference

  @impl true
  def user_allows?(_user_id, _event_id, _transport, _opts) do
    # Default: allow all notifications
    true
  end
end
