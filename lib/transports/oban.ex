defmodule AshDispatch.Transports.Oban do
  use AshDispatch.Transport,
    atom: :oban,
    skip_receipt?: true,
    required_event_metadata_keys: [:oban_worker]

  @moduledoc """
  Oban-job-enqueue transport.

  Eliminates the "two-channel dance" where a producer dispatches an
  AshDispatch event for observability AND separately calls
  `MyWorker.new(args) |> Oban.insert/1` for the side-effect work. With
  this transport, the producer dispatches once; the event declaration
  carries the worker + unique-keys in `:metadata`, and the dispatcher
  enqueues the worker as one of the event's channels.

  ## Channel config

      [transport: :oban, audience: :system]

  ## Event metadata

      event :my_event,
        channels: [
          [transport: :broadcast, audience: :admin],
          [transport: :oban,      audience: :system]
        ],
        metadata: [
          oban_worker: MyApp.Workers.DoTheThing,
          # Optional. When present, passed to `MyApp.Workers.DoTheThing.new/2`
          # as `unique: [keys: <oban_unique_keys>]`. Use to dedupe enqueues
          # on a subset of args (e.g. `[:entry_id]`).
          oban_unique_keys: [:entry_id]
        ]

  The job args are `context.data` (the third argument to `Dispatcher.dispatch/3`)
  with string keys (Oban requires JSON-serializable args; the dispatcher
  stringifies atom keys here so producers can keep idiomatic atom keys
  in their dispatch payloads).

  ## Lightweight (no receipt)

  Like `:broadcast`, this transport is **lightweight** — no
  `DeliveryReceipt` row is created (the enqueued `oban_jobs` row IS the
  audit trail). Producers who want a receipt should pair `:oban` with
  another transport on the same event.

  ## Failure semantics

  - **Missing `oban_worker` in metadata** → logs a warning, returns
    `{:ok, receipt}` with `skipped: "missing_oban_worker"`. The other
    channels still deliver. Treats configuration drift as a
    soft-fail rather than crashing producers.
  - **`Oban.insert/1` returns `{:error, _}`** → logs at `:error`,
    propagates as `{:error, reason}` (the dispatcher swallows
    per-channel errors so other channels keep delivering — matches
    the email/discord/slack precedent).
  - **Oban unavailable / not started** → caught by the `rescue`;
    returns `{:error, exception}` per the same precedent.

  ## Status

  Single consumer at ship time: Mosis (sibling repo). Extend as needed
  — same shape as the receipt-skip channels.
  """

  require Logger

  @doc """
  Enqueues the configured Oban worker with `context.data` as args.

  ## Parameters

  - `receipt` — pseudo-receipt (id: nil); not persisted for this transport
  - `context` — `AshDispatch.Context.t` with `:event_id` + `:data`
  - `channel` — `AshDispatch.Channel.t` (transport + audience only used
    for telemetry / logs)
  - `event_config` — event registration keyword list including
    `:metadata` with `:oban_worker` and optional `:oban_unique_keys`
  """
  def deliver(receipt, context, _channel, event_config) do
    metadata = event_config[:metadata] || []
    worker = Keyword.get(metadata, :oban_worker)
    unique_keys = Keyword.get(metadata, :oban_unique_keys)

    case worker do
      nil ->
        Logger.warning(
          "AshDispatch :oban transport: event #{inspect(context.event_id)} is " <>
            "registered with `transport: :oban` but no `:oban_worker` in metadata. " <>
            "Add `metadata: [oban_worker: MyApp.Workers.X]` to the event registration."
        )

        {:ok, Map.put(receipt, :status, :skipped)}

      worker_module when is_atom(worker_module) ->
        do_enqueue(receipt, context, worker_module, unique_keys)
    end
  rescue
    e ->
      Logger.error(
        "AshDispatch :oban transport: enqueue failed for #{inspect(context.event_id)} — " <>
          inspect(e)
      )

      {:error, e}
  end

  defp do_enqueue(receipt, context, worker_module, unique_keys) do
    args = stringify_keys(context.data || %{})

    new_opts =
      case unique_keys do
        keys when is_list(keys) and keys != [] -> [unique: [keys: keys]]
        _ -> []
      end

    changeset = worker_module.new(args, new_opts)

    case Oban.insert(changeset) do
      {:ok, job} ->
        Logger.debug(
          "AshDispatch :oban transport: enqueued #{inspect(worker_module)} job " <>
            "#{job.id} for event #{inspect(context.event_id)}"
        )

        {:ok, Map.put(receipt, :status, :sent)}

      {:error, reason} = err ->
        Logger.error(
          "AshDispatch :oban transport: Oban.insert/1 failed for " <>
            "#{inspect(worker_module)} on event #{inspect(context.event_id)} — " <>
            inspect(reason)
        )

        err
    end
  end

  # Oban requires JSON-serializable args (string keys). Producers
  # idiomatically pass atom-keyed data maps to Dispatcher.dispatch/3;
  # transparently coerce here so callsite shape stays clean.
  defp stringify_keys(%{} = map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
