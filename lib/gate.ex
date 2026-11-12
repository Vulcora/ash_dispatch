defmodule AshDispatch.Gate do
  @moduledoc """
  A condition on the event itself: does this go out at all?

  `should_send?/2` already exists and is the event's own last-moment guard, but
  it answers with a boolean and leaves nothing behind: a channel it refuses is
  dropped, silently, and nobody can tell afterwards whether the event was
  skipped or never fired. A gate is the same decision with a record and a
  reason.

      dispatch do
        event :reminder,
          trigger_on: :manual,
          gate: {MyApp.Bookings, :still_booked?},
          channels: [
            [transport: :email, audience: :user, time: {:in, 86_400}],
            [transport: :in_app, audience: :user]
          ]
      end

  When the gate is closed, a `:skipped` receipt exists for **every channel that
  would have been used**, each carrying the reason. "We never sent the reminder
  because the booking had been cancelled" is then a question the receipts can
  answer.

  ## It is asked twice

  - **At dispatch**, once per channel, before any recipient is delivered to.
  - **At send**, again (`AshDispatch.Delivery`) — the ask that matters for a
    delayed delivery. A reminder queued for tomorrow morning is gated now and
    gated again tomorrow, so a booking cancelled in between does not send it.

  ## What may be declared

      gate: {MyApp.Bookings, :still_booked?}          # called with the info below
      gate: {MyApp.Bookings, :open?, [:billing]}      # extra arguments appended
      gate: &MyApp.Bookings.still_booked?/1

  An event module may also implement `c:AshDispatch.Event.gate/1`. The DSL wins
  when both are present, as it does everywhere else.

  ## What it is given

  One `AshDispatch.Gate.Info` struct. At dispatch it carries the whole
  `:context` — the event's data, variables and tenant. At send it carries the
  `:receipt` and no context: a job holds ids, not structs. The fields that are
  there at both stages are the ones to write a gate against:

  - `:event_id`, `:stage` (`:dispatch` or `:send`), `:transport`, `:audience`
  - `:user_id`, `:recipient` (what the receipt is addressed to)
  - `:source_type` and `:source_id` — *what the event is about*, which is
    usually the thing a gate wants to look up
  - `:tenant`, when the dispatch knows it

  ## What it may answer

  - `true` or `:ok` — open; the event goes out.
  - `false`, `nil` or `{:ok, false}` — closed; `"event_gate_closed"`.
  - `{false, reason}`, `{:error, reason}`, `{:closed, reason}` or
    `{:skip, reason}` — closed, with the reason appended:
    `"event_gate_closed: the booking was cancelled"`.

  **Only `true` and `:ok` let the event out**, and a gate that raises closes.
  A gate exists to stop something; one that cannot answer has not said go
  ahead, and the alternative — sending because the check broke — is the failure
  a gate is there to prevent. The raise is logged as an error and the receipts
  say so.

  ## What a gate does not do

  It does not stop the event's side effects. `generate_send_variables/2` — where
  events mint tokens and write rows — has already run when the gate is asked,
  because the gate's record is per channel and the channels are not known until
  the event has been prepared. A gate decides delivery, not whether the event
  happened.
  """

  alias AshDispatch.Context
  alias AshDispatch.EventRegistry
  alias AshDispatch.EventResolver

  require Logger

  defmodule Info do
    @moduledoc """
    What a gate is told about the delivery it is deciding. See
    `AshDispatch.Gate`.
    """

    @type t :: %__MODULE__{
            event_id: String.t() | nil,
            stage: :dispatch | :send,
            transport: atom() | nil,
            audience: atom() | nil,
            user_id: term(),
            recipient: String.t() | nil,
            tenant: term(),
            source_type: String.t() | nil,
            source_id: term(),
            context: AshDispatch.Context.t() | nil,
            receipt: map() | nil
          }

    defstruct [
      :event_id,
      :stage,
      :transport,
      :audience,
      :user_id,
      :recipient,
      :tenant,
      :source_type,
      :source_id,
      :context,
      :receipt
    ]
  end

  @doc """
  The reason written on a receipt held back by a gate. A gate's own reason is
  appended to it, so both forms can be counted.
  """
  @spec reason() :: String.t()
  def reason, do: "event_gate_closed"

  @doc """
  The gate declared for an event, or `nil`.

  `event_config[:gate]` first (both send paths carry it), then the registry,
  then an event module's `c:AshDispatch.Event.gate/1`.
  """
  @spec declared(map() | keyword() | nil, String.t() | nil) :: term()
  def declared(event_config, event_id) do
    from_config(event_config) || from_registry(event_id) || from_module(event_id)
  end

  @doc """
  The verdict at dispatch, for one channel. `:open` when no gate is declared.
  """
  @spec dispatch_verdict(Context.t(), map(), map() | keyword()) :: :open | {:closed, String.t()}
  def dispatch_verdict(context, channel, event_config) do
    event_id = Map.get(context, :event_id)

    case declared(event_config, event_id) do
      nil ->
        :open

      gate ->
        ask(gate, %Info{
          event_id: event_id,
          stage: :dispatch,
          transport: Map.get(channel, :transport),
          audience: Map.get(channel, :audience),
          user_id: user_id(Map.get(context, :user)),
          tenant: Map.get(context, :tenant),
          context: context
        })
    end
  end

  @doc """
  The verdict at the moment of sending, from the receipt alone — which is all a
  job carries. `:open` when no gate is declared.
  """
  @spec send_verdict(map()) :: :send | {:skip, String.t()}
  def send_verdict(receipt) do
    event_id = Map.get(receipt, :event_id)

    case declared(nil, event_id) do
      nil ->
        :send

      gate ->
        info = %Info{
          event_id: event_id,
          stage: :send,
          transport: Map.get(receipt, :transport),
          audience: Map.get(receipt, :audience),
          user_id: Map.get(receipt, :user_id),
          recipient: Map.get(receipt, :recipient),
          source_type: Map.get(receipt, :source_type),
          source_id: Map.get(receipt, :source_id),
          receipt: receipt
        }

        case ask(gate, info) do
          :open -> :send
          {:closed, reason} -> {:skip, reason}
        end
    end
  end

  # ── Asking ──────────────────────────────────────────────────────────────

  defp ask(gate, %Info{} = info) do
    case call(gate, info) do
      true -> :open
      :ok -> :open
      {:ok, true} -> :open
      false -> closed(nil, info)
      nil -> closed(nil, info)
      {:ok, false} -> closed(nil, info)
      {false, why} -> closed(why, info)
      {:error, why} -> closed(why, info)
      {:closed, why} -> closed(why, info)
      {:skip, why} -> closed(why, info)
      {:misconfigured, value} -> misconfigured(value, info)
      other -> unexpected(other, info)
    end
  rescue
    # A gate that cannot answer has not said go ahead. The event is held and
    # the receipts say why, which is the opposite of the failure a gate exists
    # to prevent.
    error ->
      Logger.error(
        "ash_dispatch: the gate on #{info.event_id} raised (#{info.stage}, " <>
          "#{info.transport}): #{Exception.message(error)}. The event is not sent."
      )

      {:closed, reason() <> ": the gate raised"}
  end

  # Before the {module, function} clause: `{:callback, module}` is a pair of
  # atoms too, and would otherwise be called as `apply(:callback, module, ...)`.
  defp call({:callback, module}, info), do: module.gate(info)

  defp call({module, function}, info) when is_atom(module) and is_atom(function),
    do: apply(module, function, [info])

  defp call({module, function, extra}, info)
       when is_atom(module) and is_atom(function) and is_list(extra),
       do: apply(module, function, [info | extra])

  defp call(gate, info) when is_function(gate, 1), do: gate.(info)
  defp call(gate, _info), do: {:misconfigured, gate}

  defp closed(nil, info) do
    log(info, reason())
    {:closed, reason()}
  end

  defp closed(why, info) do
    why = if is_binary(why), do: why, else: inspect(why)
    log(info, why)
    {:closed, reason() <> ": " <> why}
  end

  defp misconfigured(value, info) do
    Logger.error("""
    ash_dispatch: the gate on #{info.event_id} is #{inspect(value)}, which cannot be called.

    Expected {module, function}, {module, function, extra_args}, or a
    one-argument function. The event is not sent until this is fixed.
    """)

    closed("the gate cannot be called", info)
  end

  defp unexpected(other, info) do
    Logger.error(
      "ash_dispatch: the gate on #{info.event_id} answered #{inspect(other)}, which is not " <>
        "an answer. Only true and :ok let an event out."
    )

    closed("the gate gave no answer", info)
  end

  defp log(info, why) do
    Logger.info(
      "Gate closed for #{info.event_id} (#{info.stage}, #{info.transport}/#{info.audience}): #{why}"
    )
  end

  # ── Where a gate is declared ────────────────────────────────────────────

  defp from_config(event_config) when is_map(event_config), do: Map.get(event_config, :gate)

  defp from_config(event_config) when is_list(event_config) do
    if Keyword.keyword?(event_config), do: Keyword.get(event_config, :gate)
  end

  defp from_config(_event_config), do: nil

  defp from_registry(nil), do: nil

  defp from_registry(event_id) do
    case EventRegistry.find_event(event_id) do
      {:ok, event} -> Map.get(event, :gate)
      _ -> nil
    end
  end

  defp from_module(nil), do: nil

  defp from_module(event_id) do
    with {:ok, module} <- EventResolver.find_module(event_id),
         true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :gate, 1) do
      {:callback, module}
    else
      _ -> nil
    end
  end

  defp user_id(%{id: id}), do: id
  defp user_id(%{"id" => id}), do: id
  defp user_id(_user), do: nil
end
