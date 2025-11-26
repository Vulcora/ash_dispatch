defmodule AshDispatch.Behaviours.PreferenceProvider do
  @moduledoc """
  Behavior for checking user email preferences.

  This behavior allows apps to implement their own preference checking logic,
  from simple field-based preferences to complex multi-tenant scenarios.

  ## Simple Implementation

  For straightforward preference systems (like Magasin):

      defmodule MyApp.PreferenceProvider do
        @behaviour AshDispatch.Behaviours.PreferenceProvider

        def get_preferences(user_id) do
          MyApp.Accounts.get_user_email_preferences(user_id, authorize?: false)
        end

        def preference_enabled?(preferences, category) when is_atom(category) do
          Map.get(preferences, category, true)
        end
      end

  ## Complex Implementation

  For advanced scenarios with dynamic preferences:

      defmodule MyApp.AdvancedPreferenceProvider do
        @behaviour AshDispatch.Behaviours.PreferenceProvider

        def get_preferences(user_id) do
          # Load preferences from multiple sources
          # Apply tenant-specific rules
          # Handle preference hierarchies
          {:ok, combined_preferences}
        end

        def preference_enabled?(preferences, category) do
          # Complex logic considering:
          # - User tier
          # - Regulatory requirements
          # - Business rules
          MyApp.PreferenceEngine.check(preferences, category)
        end
      end

  ## Configuration

  Configure the preference provider in your app's config:

      config :ash_dispatch,
        preference_provider: MyApp.PreferenceProvider
  """

  @doc """
  Get email preferences for a user.

  Returns `{:ok, preferences}` map or `{:error, reason}`.

  The preferences map should contain email preference categories as keys.
  """
  @callback get_preferences(user_id :: String.t()) :: {:ok, map()} | {:error, term()}

  @doc """
  Check if a specific preference category is enabled for the user.

  Takes the preferences map (from `get_preferences/1`) and a category atom.
  Returns `true` if enabled, `false` if disabled.

  Default to `true` if category not found (opt-in model).
  """
  @callback preference_enabled?(preferences :: map(), category :: atom()) :: boolean()
end
