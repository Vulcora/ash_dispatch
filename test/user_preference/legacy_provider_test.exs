defmodule AshDispatch.UserPreference.LegacyProviderTest do
  @moduledoc """
  The bridge between the library's two preference systems.

  The bug this closes is not a crash. An app configures
  `:preference_provider`, the rule it encodes is real and correct, and it is
  applied to email and to nothing else — because the transport gate reads a
  DIFFERENT config key. Nothing ever said so. The first test below records
  that behaviour as a fact rather than as a claim in a moduledoc, so the day
  it changes, it changes on purpose.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AshDispatch.Channel
  alias AshDispatch.Context
  alias AshDispatch.Transports.Preferences
  alias AshDispatch.UserPreference
  alias AshDispatch.UserPreference.LegacyProvider

  @user "33333333-3333-3333-3333-333333333333"

  defmodule InaktivaFarInget do
    @moduledoc false
    @behaviour AshDispatch.Behaviours.PreferenceProvider

    @impl true
    def get_preferences("33333333-3333-3333-3333-333333333333"),
      do: {:ok, %{__inactive__: true}}

    def get_preferences("nere"), do: {:error, :preference_store_unreachable}
    def get_preferences(_), do: {:ok, %{}}

    @impl true
    def preference_enabled?(prefs, _category), do: not Map.get(prefs, :__inactive__, false)
  end

  setup do
    tidigare_leverantor = Application.get_env(:ash_dispatch, :preference_provider)
    tidigare_checker = Application.get_env(:ash_dispatch, :user_preference)

    on_exit(fn ->
      aterstall(:preference_provider, tidigare_leverantor)
      aterstall(:user_preference, tidigare_checker)
    end)

    :ok
  end

  defp aterstall(nyckel, nil), do: Application.delete_env(:ash_dispatch, nyckel)
  defp aterstall(nyckel, varde), do: Application.put_env(:ash_dispatch, nyckel, varde)

  defp kanal(transport), do: %Channel{transport: transport, audience: :user}
  defp sammanhang, do: %Context{event_id: "meeting.reminder", data: %{}, user: nil}

  describe "the gap the bridge exists to close" do
    test "a provider alone does not reach the transport gate" do
      # This is the finding, executable. `InaktivaFarInget` says this user
      # receives nothing — and the gate says deliver, on every transport,
      # because it reads :user_preference and the provider is :preference_provider.
      Application.put_env(:ash_dispatch, :preference_provider, InaktivaFarInget)
      Application.delete_env(:ash_dispatch, :user_preference)

      for transport <- [:email, :sms, :push, :in_app, :slack, :discord, :webhook] do
        assert UserPreference.allows_receipt?(
                 %{user_id: @user},
                 sammanhang(),
                 kanal(transport),
                 []
               ),
               """
               #{transport}: the gate now consults :preference_provider on its own.

               If that is intended, this test should be deleted and the bridge
               with it — but the change is a behaviour change for every app that
               configured a provider expecting email-only scope, so it must be
               deliberate.
               """
      end
    end

    test "with the bridge wired, the same provider answers for every transport" do
      Application.put_env(:ash_dispatch, :preference_provider, InaktivaFarInget)
      Application.put_env(:ash_dispatch, :user_preference, LegacyProvider)

      for transport <- [:email, :sms, :push, :in_app, :slack, :discord, :webhook] do
        refute UserPreference.allows_receipt?(
                 %{user_id: @user},
                 sammanhang(),
                 kanal(transport),
                 []
               ),
               "#{transport} still delivers to a recipient the provider excludes"
      end
    end
  end

  describe "the bridge keeps SendEmail's semantics" do
    setup do
      Application.put_env(:ash_dispatch, :user_preference, LegacyProvider)
      :ok
    end

    test "an unreachable preference store allows the send" do
      # SendEmail's own comment: better to send than to silently skip. A
      # store that is down must not become a mute button — the failure would
      # be invisible to everyone, including the recipient.
      Application.put_env(:ash_dispatch, :preference_provider, InaktivaFarInget)

      assert LegacyProvider.user_allows?("nere", "meeting.reminder", :sms, category: nil)
    end

    test "no provider configured allows the send" do
      Application.delete_env(:ash_dispatch, :preference_provider)

      assert LegacyProvider.user_allows?(@user, "meeting.reminder", :sms, category: nil)
    end

    test "a permitted recipient is allowed" do
      Application.put_env(:ash_dispatch, :preference_provider, InaktivaFarInget)

      assert LegacyProvider.user_allows?("nagon-annan", "meeting.reminder", :sms, category: nil)
    end

    test "the provider's own verdict decides" do
      Application.put_env(:ash_dispatch, :preference_provider, InaktivaFarInget)

      refute LegacyProvider.user_allows?(@user, "meeting.reminder", :sms, category: nil)
    end
  end

  describe "the orphaned-provider warning" do
    setup do
      # The warning fires once per VM and other tests in this suite reach the
      # gate first, so the latch has to be cleared to observe it at all.
      :persistent_term.erase({Preferences, :varnat})
      on_exit(fn -> :persistent_term.put({Preferences, :varnat}, true) end)
      :ok
    end

    test "it fires when a provider is configured and the gate is not" do
      Application.put_env(:ash_dispatch, :preference_provider, InaktivaFarInget)
      Application.delete_env(:ash_dispatch, :user_preference)

      logg =
        capture_log(fn ->
          Preferences.with_consent(%{user_id: nil}, sammanhang(), kanal(:sms), [], fn -> :ok end)
        end)

      assert logg =~ ":preference_provider is configured but :user_preference is not"
      assert logg =~ "AshDispatch.UserPreference.LegacyProvider"
    end

    test "it stays quiet once the gate is configured" do
      Application.put_env(:ash_dispatch, :preference_provider, InaktivaFarInget)
      Application.put_env(:ash_dispatch, :user_preference, LegacyProvider)

      logg =
        capture_log(fn ->
          Preferences.with_consent(%{user_id: nil}, sammanhang(), kanal(:sms), [], fn -> :ok end)
        end)

      refute logg =~ ":preference_provider is configured but"
    end

    test "it stays quiet when no provider is configured" do
      Application.delete_env(:ash_dispatch, :preference_provider)
      Application.delete_env(:ash_dispatch, :user_preference)

      logg =
        capture_log(fn ->
          Preferences.with_consent(%{user_id: nil}, sammanhang(), kanal(:sms), [], fn -> :ok end)
        end)

      refute logg =~ ":preference_provider is configured but"
    end

    test "it fires once, not on every delivery" do
      # A warning on every send is a warning nobody reads, and this one sits
      # on the path of every notification the app sends.
      Application.put_env(:ash_dispatch, :preference_provider, InaktivaFarInget)
      Application.delete_env(:ash_dispatch, :user_preference)

      skicka = fn ->
        capture_log(fn ->
          Preferences.with_consent(%{user_id: nil}, sammanhang(), kanal(:sms), [], fn -> :ok end)
        end)
      end

      assert skicka.() =~ ":preference_provider is configured but"
      refute skicka.() =~ ":preference_provider is configured but"
    end
  end
end
