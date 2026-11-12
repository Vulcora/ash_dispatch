defmodule AshDispatch.DeliveryMode do
  @moduledoc """
  Whether a delivery really leaves this machine — for every transport, not
  only email.

  Until 0.9.3 there was one such setting, `skip_email_delivery`, and it covered
  email alone. A staging host with it switched on still sent SMS, still posted
  webhooks and still pushed to browsers: the one transport people remember to
  hold back was held back, and the six they forget were not.

  One setting now answers the question for all of them:

      config :ash_dispatch, delivery_mode: :live

  - `:live` — send. The default, and what every host that sets nothing gets.
  - `:blocked` — never send. The receipt is `:skipped` and says it was held
    back.
  - `:dry_run` — go through everything: render, create the receipt, enqueue the
    job, run the worker — and then send nothing. The receipt holds the letter
    that would have gone out, and says it did not.
  - `{:allow_list, [...]}` — send only to these recipients. Everyone else is
    treated as `:blocked`. For a staging host that must be able to mail its own
    team and nobody else.

  ## Per transport

      config :ash_dispatch,
        delivery_mode: [
          default: :dry_run,
          email: {:allow_list, ["ops@example.com", "@example.test"]},
          in_app: :live
        ]

  `:default` answers for every transport not named. Without a `:default`, an
  unnamed transport is `:live` — the same as setting nothing at all.

  ## The allow-list

  An entry matches a recipient when it is

  - the recipient itself, case ignored (`"ops@example.com"`);
  - a domain, with or without the `@` (`"@example.test"`, `"example.test"`) —
    matches every address in it;
  - a phone prefix (`"+4670"`) — matches every number that starts with it,
    separators ignored. An allow-list must use the same format as the
    recipients it is matched against: `"+4670"` does not match `"0701234567"`;
  - a prefix with an explicit `*` (`"team-*"`, `"+4670*"`);
  - `"*"`, which matches everything.

  A recipient that is missing or empty never matches: an allow-list exists so
  that nothing escapes, so it fails closed.

  ## `skip_email_delivery`

  `config :ash_dispatch, skip_email_delivery: true` keeps working and means
  exactly what it always did: email is blocked, and the receipt carries the
  reason it always carried (`"email delivery disabled (dev mode)"`). It is read
  as `delivery_mode: [email: :blocked]`, and an explicit `:email` entry in
  `delivery_mode` wins over it.

  ## Where it is asked

  At the moment of sending, once per delivery: in the send workers
  (`AshDispatch.Workers.SendEmail`, `SendSMS`, `SendWebhook`) and, for the
  transports that deliver synchronously, immediately before the write
  (`AshDispatch.Transports.InApp`, `Push`). A blocked delivery therefore still
  gets its receipt and its job — which is the point: the receipt records the
  letter that was held back, and `:dry_run` exercises the whole path.

  The two receipt-less transports, `:broadcast` and `:oban`, are not covered:
  they reach a PubSub topic and a queue in the same system, not a person, and
  they have no receipt to record a hold on.

  See also `AshDispatch.Delivery`, which asks this question together with the
  recipient's eligibility and the event's gate.
  """

  require Logger

  @type allow_list :: [String.t()]
  @type t :: :live | :blocked | :dry_run | {:allow_list, allow_list()}

  @simple_modes [:live, :blocked, :dry_run]
  @legacy_reason "email delivery disabled (dev mode)"

  @doc """
  The reason written on a receipt that was held back.

  Public so the reasons can be counted: a dashboard that wants "how much would
  this host have sent" filters on `reason(:dry_run)`.
  """
  @spec reason(:blocked | :dry_run | :not_allowed | :legacy_email) :: String.t()
  def reason(:blocked), do: "delivery_blocked"
  def reason(:dry_run), do: "delivery_dry_run"
  def reason(:not_allowed), do: "delivery_not_allowed"
  def reason(:legacy_email), do: @legacy_reason

  @doc """
  The mode in force for `transport`.

  Reads `config :ash_dispatch, :delivery_mode` (and, for `:email`,
  `:skip_email_delivery`). `:live` when nothing is configured.
  """
  @spec for_transport(atom()) :: t()
  def for_transport(transport) do
    {mode, _source} = resolve(transport)
    mode
  end

  @doc """
  May this delivery really go out?

  Returns `:send`, or `{:skip, reason}` with the reason to write on the
  receipt.

  `identifier` is what the receipt was addressed to: an email address, a phone
  number, a webhook URL. It is only read by an allow-list.
  """
  @spec verdict(atom(), term()) :: :send | {:skip, String.t()}
  def verdict(transport, identifier) do
    case resolve(transport) do
      {:live, _source} ->
        :send

      {:blocked, :skip_email_delivery} ->
        {:skip, @legacy_reason}

      {:blocked, _source} ->
        {:skip, reason(:blocked)}

      {:dry_run, _source} ->
        {:skip, reason(:dry_run)}

      {{:allow_list, entries}, _source} ->
        if allowed?(identifier, entries), do: :send, else: {:skip, reason(:not_allowed)}
    end
  end

  @doc """
  Whether `identifier` is on `allow_list`. See the module doc for the matching
  rules.
  """
  @spec allowed?(term(), allow_list()) :: boolean()
  def allowed?(_identifier, []), do: false

  def allowed?(identifier, allow_list) when is_list(allow_list) do
    case address(identifier) do
      nil -> false
      value -> Enum.any?(allow_list, &matches?(value, normalise_entry(&1)))
    end
  end

  def allowed?(_identifier, _allow_list), do: false

  # ── Resolution ──────────────────────────────────────────────────────────
  #
  # Precedence, most specific first:
  #
  #   1. `delivery_mode: [email: ...]` — this transport, named
  #   2. `skip_email_delivery: true`   — email only, the 0.9.2 setting
  #   3. `delivery_mode: :dry_run` or `delivery_mode: [default: ...]`
  #   4. `:live`
  #
  # `skip_email_delivery` sits above the global setting on purpose: a host that
  # had it switched on and then sets `delivery_mode: :live` globally must not
  # start mailing people from its development machine.
  @spec resolve(atom()) :: {t(), atom()}
  defp resolve(transport) do
    configured = AshDispatch.Config.delivery_mode()

    cond do
      mode = per_transport(configured, transport) ->
        {mode, :transport}

      transport == :email and AshDispatch.Config.skip_email_delivery?() ->
        {:blocked, :skip_email_delivery}

      mode = global(configured) ->
        {mode, :global}

      true ->
        {:live, :default}
    end
  end

  defp per_transport(configured, transport) do
    if per_transport_form?(configured) do
      configured |> Keyword.get(transport) |> normalise()
    end
  end

  defp global(configured) do
    if per_transport_form?(configured) do
      configured |> Keyword.get(:default) |> normalise()
    else
      normalise(configured)
    end
  end

  # `[default: :blocked, email: :live]` is a per-transport table.
  # `[allow_list: [...]]` is a mode — the keyword spelling of
  # `{:allow_list, [...]}`, which reads better in a config file.
  defp per_transport_form?(configured) do
    is_list(configured) and Keyword.keyword?(configured) and
      not Keyword.has_key?(configured, :allow_list)
  end

  defp normalise(nil), do: nil
  defp normalise(mode) when mode in @simple_modes, do: mode

  defp normalise({:allow_list, entries}) when is_list(entries),
    do: {:allow_list, Enum.map(entries, &normalise_entry/1)}

  defp normalise(allow_list: entries) when is_list(entries),
    do: normalise({:allow_list, entries})

  defp normalise(other) do
    warn_once(other)
    nil
  end

  # A typo in a safety setting is reported, loudly and once, and then treated
  # as "not configured". The alternative — refusing to deliver anything — turns
  # a misspelling into an outage, and a library has no business making that
  # choice for a host at three in the morning.
  defp warn_once(value) do
    key = {__MODULE__, :warned, value}

    if not :persistent_term.get(key, false) do
      :persistent_term.put(key, true)

      Logger.error("""
      ash_dispatch: :delivery_mode is set to #{inspect(value)}, which is not a delivery mode.

      Expected :live, :blocked, :dry_run, {:allow_list, ["..."]}, or a keyword
      list per transport such as [default: :dry_run, email: :live].

      Deliveries run as :live until this is fixed.
      """)
    end
  end

  # ── Allow-list matching ─────────────────────────────────────────────────

  defp normalise_entry(entry) when is_binary(entry),
    do: entry |> String.trim() |> String.downcase()

  defp normalise_entry(entry), do: entry |> to_string() |> normalise_entry()

  # What the receipt was addressed to. The transports pass a string; a
  # `{name, address}` tuple and a map that holds an address are accepted for
  # the same reason `AshDispatch.Log.recipient/1` accepts them.
  defp address(value) when is_binary(value) do
    case normalise_entry(value) do
      "" -> nil
      address -> address
    end
  end

  defp address({_name, address}) when is_binary(address), do: address(address)

  defp address(%{} = value) do
    Enum.find_value([:email, :phone, :phone_number, :address], fn key ->
      case Map.get(value, key) do
        found when is_binary(found) -> address(found)
        _ -> nil
      end
    end)
  end

  defp address(_value), do: nil

  defp matches?(_value, "*"), do: true

  defp matches?(value, "@" <> _rest = domain), do: String.ends_with?(value, domain)

  defp matches?(value, entry) do
    cond do
      String.ends_with?(entry, "*") ->
        String.starts_with?(value, String.trim_trailing(entry, "*"))

      phone?(value) and phone?(entry) ->
        String.starts_with?(digits(value), digits(entry))

      String.contains?(value, "@") and domain_only?(entry) ->
        String.ends_with?(value, "@" <> entry)

      true ->
        value == entry
    end
  end

  defp domain_only?(entry), do: not String.contains?(entry, "@") and String.contains?(entry, ".")

  defp phone?(value) do
    Regex.match?(~r/^\+?[\d\s\-().]+$/, value) and String.length(digits(value)) >= 4
  end

  defp digits(value), do: String.replace(value, ~r/\D/, "")
end
