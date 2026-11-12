defmodule AshDispatch.EligibleRecipient do
  @moduledoc """
  May this recipient be reached at all?

  Preferences answer a different question. A preference is what a person *wants*
  — and a mandatory event (`metadata: [user_configurable: false]`) overrides it,
  deliberately: a password reset is not a marketing choice. But that override
  used to be total. A closed account, a barred user, an address that was never
  verified — a mandatory event walked past all of it and the letter went out,
  because nothing in the library had ever been told that some recipients must
  not be reached whatever the message is.

  This is where a host says so:

      # config/config.exs
      config :ash_dispatch, eligible_recipient: MyApp.Notifications.Eligibility

      defmodule MyApp.Notifications.Eligibility do
        @behaviour AshDispatch.EligibleRecipient

        @impl true
        def eligible?(_recipient, opts) do
          case MyApp.Accounts.get_user(opts[:user_id]) do
            {:ok, %{deactivated_at: nil, blocked: false}} -> true
            {:ok, _user} -> {false, "account closed"}
            _ -> true
          end
        end
      end

  Without a check configured nothing is asked and nothing changes.

  ## It is asked twice

  - **When the recipients are resolved**, once per receipt, before the transport
    is given anything to do. The receipt exists and is `:skipped` with the
    reason, so an ineligible recipient is never a silent drop: the audit trail
    says a letter was written for this person and held back, and why.
  - **At the moment of sending**, again (`AshDispatch.Delivery`). A delivery can
    wait in a queue for hours — `delay: 86_400`, a retry, a stranded job — and
    the answer may have changed while it waited. The second ask is the one that
    matters for a reminder scheduled yesterday for an account closed this
    morning.

  It is asked for **every** event, mandatory ones included. That is the point of
  it.

  ## What may be configured

      config :ash_dispatch, eligible_recipient: MyApp.Eligibility          # eligible?/2
      config :ash_dispatch, eligible_recipient: {MyApp.Eligibility, :check?}
      config :ash_dispatch, eligible_recipient: {MyApp.Eligibility, :check?, [:extra]}
      config :ash_dispatch, eligible_recipient: &MyApp.Eligibility.check?/2

  ## What it is given

  `recipient` is the resolved recipient — a user struct or a recipient map — when
  the check runs at resolve time, and `nil` at send time: a job carries ids, not
  structs. Everything else is in `opts`:

  - `:stage` — `:resolve` or `:send`
  - `:user_id` — the recipient's user id, or `nil` for a recipient without an
    account
  - `:identifier` — what the receipt is addressed to: the address, the phone
    number
  - `:event_id`, `:transport`, `:audience`, `:tenant`
  - `:receipt_id` — the receipt this verdict decides, when there is one

  Read `opts[:user_id]` (and `opts[:identifier]`) rather than the recipient
  struct if you want one implementation that answers at both stages.

  ## What it may answer

  - `true`, `:ok` or `{:ok, true}` — reachable.
  - `false`, `nil` or `{:ok, false}` — not reachable; the receipt is `:skipped`
    with `"recipient_ineligible"`.
  - `{false, reason}`, `{:error, reason}` or `{:ineligible, reason}` — not
    reachable, with the reason appended: `"recipient_ineligible: account
    closed"`.

  **Only `true`, `:ok` and `{:ok, true}` let a delivery through**, and a check
  that raises holds the delivery back. This fails closed on purpose: the
  question is whether a person may be contacted, and a host that cannot answer
  it has not said yes. A check that cannot answer therefore stops the delivery
  and says so on the receipt and in the log — loudly, and where it can be found.

  ## Cost

  It is called once per recipient per stage, so a fan-out to 500 people asks
  500 times. Keep it cheap, or keep what it reads for the rest of the dispatch
  with `AshDispatch.UserPreference.scope_get/1` and `scope_put/2`.
  """

  alias AshDispatch.Config

  require Logger

  @doc """
  Whether `recipient` may be reached. See the module doc for the opts and the
  answers.
  """
  @callback eligible?(recipient :: term(), opts :: keyword()) ::
              true
              | false
              | nil
              | :ok
              | {:ok, boolean()}
              | {false, String.t()}
              | {:error, term()}
              | {:ineligible, term()}

  @doc """
  The reason written on a receipt whose recipient could not be reached. A host's
  own reason is appended to it, so both forms can be counted.
  """
  @spec reason() :: String.t()
  def reason, do: "recipient_ineligible"

  @doc "Whether a host has configured a check at all."
  @spec configured?() :: boolean()
  def configured?, do: not is_nil(Config.eligible_recipient())

  @doc """
  The verdict when the recipients of a channel have just been resolved.

  `:send`, or `{:skip, reason}` to record on the receipt.
  """
  @spec resolve_verdict(map(), map(), map(), term(), term()) :: :send | {:skip, String.t()}
  def resolve_verdict(receipt, context, channel, _event_config, recipient) do
    verdict(recipient,
      stage: :resolve,
      user_id: Map.get(receipt, :user_id),
      identifier: Map.get(receipt, :recipient),
      event_id: Map.get(context, :event_id),
      transport: Map.get(channel, :transport),
      audience: Map.get(channel, :audience),
      tenant: Map.get(context, :tenant),
      receipt_id: Map.get(receipt, :id)
    )
  end

  @doc """
  The verdict at the moment of sending, from the receipt alone — which is all a
  job carries.
  """
  @spec send_verdict(map()) :: :send | {:skip, String.t()}
  def send_verdict(receipt) do
    verdict(nil,
      stage: :send,
      user_id: Map.get(receipt, :user_id),
      identifier: Map.get(receipt, :recipient),
      event_id: Map.get(receipt, :event_id),
      transport: Map.get(receipt, :transport),
      audience: Map.get(receipt, :audience),
      tenant: nil,
      receipt_id: Map.get(receipt, :id)
    )
  end

  @doc """
  Asks the configured check directly. `:send` when none is configured.

  Public so a host can ask the same question its own screens ask — "would this
  person be reached?" — and be certain of getting the answer the send path will
  reach.
  """
  @spec verdict(term(), keyword()) :: :send | {:skip, String.t()}
  def verdict(recipient, opts) do
    case Config.eligible_recipient() do
      nil -> :send
      check -> interpret(check, recipient, opts)
    end
  end

  defp ask(check, recipient, opts) when is_atom(check), do: check.eligible?(recipient, opts)

  defp ask({module, function}, recipient, opts) when is_atom(module) and is_atom(function),
    do: apply(module, function, [recipient, opts])

  defp ask({module, function, extra}, recipient, opts)
       when is_atom(module) and is_atom(function) and is_list(extra),
       do: apply(module, function, [recipient, opts | extra])

  defp ask(check, recipient, opts) when is_function(check, 2), do: check.(recipient, opts)

  defp ask(check, _recipient, _opts), do: {:misconfigured, check}

  # The rescue has to wrap the call itself, not only the reading of its answer:
  # a check that raises is the case this exists for.
  defp interpret(check, recipient, opts) do
    case ask(check, recipient, opts) do
      true -> :send
      :ok -> :send
      {:ok, true} -> :send
      false -> ineligible(nil, opts)
      nil -> ineligible(nil, opts)
      {:ok, false} -> ineligible(nil, opts)
      {false, reason} -> ineligible(reason, opts)
      {:error, reason} -> ineligible(reason, opts)
      {:ineligible, reason} -> ineligible(reason, opts)
      {:misconfigured, check} -> misconfigured(check, opts)
      other -> unexpected(other, opts)
    end
  rescue
    # Fails closed: a check that cannot answer has not said yes. The delivery
    # is held, not lost - the receipt keeps the letter, and the reason says
    # where to look.
    error ->
      Logger.error(
        "ash_dispatch: the :eligible_recipient check raised for #{inspect(opts[:user_id])} " <>
          "(#{opts[:event_id]}, #{opts[:stage]}): #{Exception.message(error)}. " <>
          "The delivery is held back."
      )

      {:skip, reason() <> ": the eligibility check raised"}
  end

  defp ineligible(nil, opts) do
    log(opts, reason())
    {:skip, reason()}
  end

  defp ineligible(detail, opts) do
    detail = if is_binary(detail), do: detail, else: inspect(detail)
    log(opts, detail)
    {:skip, reason() <> ": " <> detail}
  end

  defp misconfigured(check, opts) do
    Logger.error("""
    ash_dispatch: :eligible_recipient is set to #{inspect(check)}, which cannot be called.

    Expected a module implementing AshDispatch.EligibleRecipient, {module, function},
    {module, function, extra_args}, or a two-argument function.

    Deliveries are held back until this is fixed.
    """)

    ineligible("the eligibility check cannot be called", opts)
  end

  defp unexpected(other, opts) do
    Logger.error(
      "ash_dispatch: the :eligible_recipient check answered #{inspect(other)}, which is not " <>
        "an answer. Only true, :ok and {:ok, true} let a delivery through."
    )

    ineligible("the eligibility check gave no answer", opts)
  end

  defp log(opts, detail) do
    Logger.info(
      "Recipient #{inspect(opts[:user_id])} cannot be reached for #{opts[:event_id]} " <>
        "via #{opts[:transport]} (#{opts[:stage]}): #{AshDispatch.Log.redact_text(detail)}"
    )
  end
end
