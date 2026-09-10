defmodule AshDispatch.UserPreference.LegacyProvider do
  @moduledoc """
  Bridges a configured `:preference_provider` into the transport gate.

  ## Why this exists

  ash_dispatch grew two preference systems that never met:

  | | read by | configured as |
  |---|---|---|
  | `AshDispatch.UserPreference` | every transport, via `allows_receipt?/4` | `:user_preference` |
  | `AshDispatch.Behaviours.PreferenceProvider` | the `SendEmail` worker and manual triggers | `:preference_provider` |

  An app that wired only the second one — and the documentation pointed
  there for years — has its rule honoured **on email and nowhere else**.
  Nothing reports this. The preference is not broken; it is partly
  honoured, which is worse, because the person who set it believes it
  applies.

  This module makes the second system answer for all seven transports:

      config :ash_dispatch,
        preference_provider: MyApp.PreferenceProvider,
        user_preference: AshDispatch.UserPreference.LegacyProvider

  ## The semantics are SendEmail's, deliberately

  Wiring this must not change what email already does, or the fix would
  trade one surprise for another. So the three edges are copied from
  `AshDispatch.Workers.SendEmail.check_user_preferences/1`:

  - no provider configured ⇒ allow (there is no rule to apply)
  - `get_preferences/1` returns `{:error, _}` ⇒ **allow**. An unreachable
    preference store must not silence a notification: a missed send is
    visible to the recipient, a wrongly-skipped one is visible to nobody.
  - otherwise the provider's own `preference_enabled?/2` decides

  A `nil` user_id never reaches here — `AshDispatch.UserPreference.allows_user?/4`
  answers `true` for recipients with no user before consulting any checker.

  ## This is a bridge, not a destination

  New apps should implement `AshDispatch.UserPreference` directly: it
  receives the event id and the transport, so a rule can differ per
  channel ("no SMS at night, email is fine"). `PreferenceProvider` sees
  only the category and cannot express that.
  """

  @behaviour AshDispatch.UserPreference

  alias AshDispatch.Config

  @impl true
  def user_allows?(user_id, _event_id, _transport, opts) do
    case Config.preference_provider() do
      nil ->
        true

      provider ->
        case provider.get_preferences(user_id) do
          {:ok, preferences} -> provider.preference_enabled?(preferences, opts[:category])
          {:error, _reason} -> true
        end
    end
  end
end
