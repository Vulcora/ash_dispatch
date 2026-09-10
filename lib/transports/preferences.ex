defmodule AshDispatch.Transports.Preferences do
  @moduledoc """
  The opt-out gate, in one place.

  Every transport that reaches a person must ask the same question before it
  delivers: *did this recipient say no?* Until 0.7.0 only `:email`, `:in_app`
  and `:webhook` asked. `:slack`, `:discord`, `:sms` and `:push` did not —
  which meant a preference honoured on one channel was silently ignored on
  another, and the difference was invisible to the person who set it.

  ## Why a shared function rather than a copied block

  The check is eight lines, and eight lines copied six times is six chances
  to drift. The copies had already begun to: `:in_app` logged the user id,
  `:webhook` logged the receipt id, and neither said which was intended. One
  implementation makes the verdict, the skip reason and the log line the same
  everywhere — and `"user_opted_out"` becomes a value you can count.

  ## The verdict is per RECIPIENT, not per event

  A receipt is one recipient. `allows_receipt?/4` reads the receipt's own
  `user_id`; reading `context.user` would apply the event subject's verdict
  to all N recipients of a fan-out — the bug this function exists to make
  impossible to reintroduce.
  """

  alias AshDispatch.Config
  alias AshDispatch.UserPreference

  require Logger

  @skalet "user_opted_out"

  @doc """
  Runs `fun` when the recipient allows this delivery, otherwise skips.

  The skipped receipt is returned as `{:ok, receipt}` — a skip is a
  successful outcome, not a failure. The person said no, and we did what
  they asked.
  """
  @spec with_consent(map(), map(), map(), keyword(), (-> term())) :: term()
  def with_consent(receipt, context, channel, event_config, fun) do
    varna_om_foraldralos_leverantor()

    if UserPreference.allows_receipt?(receipt, context, channel, event_config) do
      fun.()
    else
      Logger.info(
        "Recipient #{inspect(Map.get(receipt, :user_id))} opted out of " <>
          "#{inspect(Map.get(context, :event_id))} via #{inspect(Map.get(channel, :transport))}, skipping"
      )

      {:ok, skip(receipt)}
    end
  end

  @doc "The reason written on a receipt skipped by an opt-out. Public so it can be counted."
  @spec reason() :: String.t()
  def reason, do: @skalet

  # ash_dispatch has two preference systems and they never met: this gate
  # reads `:user_preference`, while the `SendEmail` worker and the manual
  # triggers read `:preference_provider`. An app that configured only the
  # latter — which the guides pointed at for years — has its rule honoured
  # on EMAIL and on nothing else.
  #
  # Nothing reported that. The rule looked configured, was configured, and
  # silently covered one transport of seven. So the library says it out
  # loud, once per VM: a partly-honoured preference is worse than an absent
  # one, because the person who set it believes it applies.
  defp varna_om_foraldralos_leverantor do
    # The condition is evaluated BEFORE the latch is set. Latching first
    # would mean the warning only ever fires if the misconfiguration exists
    # at the moment of the very first delivery — an app that sets the
    # provider later would be latched into silence by a delivery that had
    # nothing to warn about. A warning that can quietly fail to appear is
    # the exact bug this warning exists to report.
    #
    # The cost of asking every time is two ETS reads, which is less than the
    # cost of being wrong about it.
    if Config.preference_provider() &&
         Config.user_preference() == AshDispatch.UserPreference.Default do
      if not :persistent_term.get({__MODULE__, :varnat}, false) do
        :persistent_term.put({__MODULE__, :varnat}, true)

        Logger.warning("""
        ash_dispatch: :preference_provider is configured but :user_preference is not.

        Those are two different systems. `#{inspect(Config.preference_provider())}` is
        consulted by the SendEmail worker and by manual triggers — and by NOTHING
        else. Deliveries over :sms, :push, :in_app, :slack, :discord and :webhook
        ignore it entirely, so the rule it encodes is honoured on email alone.

        To apply the same rule on every transport:

            config :ash_dispatch,
              user_preference: AshDispatch.UserPreference.LegacyProvider

        That bridge delegates to the provider you already have, with SendEmail's
        exact semantics. Note that it is a BEHAVIOUR CHANGE: recipients the
        provider excludes stop receiving on the other six transports too, which
        is presumably what was meant — but it should be a decision, not a
        surprise.

        Configure :user_preference (to the bridge or to your own checker) to
        silence this.
        """)
      end
    end
  end

  defp skip(receipt) do
    receipt
    |> Ash.Changeset.for_update(:skip, %{error_message: @skalet})
    |> Ash.update!(authorize?: false)
  end
end
