defmodule AshDispatch.Event.CustomTopic do
  @moduledoc """
  Lightweight `:custom_topic` transport for `AshDispatch.Event`.

  Some events are fire-and-forget per-record PubSub broadcasts to a
  fixed (or per-record) topic — no recipients, no content rendering,
  no `DeliveryReceipt` rows. The full `AshDispatch.Event` Spark DSL +
  `Dispatcher` pipeline is the wrong shape for that workload: it
  exists to fan a single event out across N channels with per-
  audience templates and receipts.

  `use AshDispatch.Event, transports: [custom_topic: [...]]` injects a
  thin helper layer that bypasses the dispatcher and calls
  `Phoenix.PubSub.broadcast/3` directly, with the safe-broadcast +
  telemetry wrapping that hand-rolled broadcasters were otherwise
  re-implementing.

  ## Usage

      defmodule MyApp.Events.SomethingHappened do
        use AshDispatch.Event,
          transports: [
            custom_topic: [
              pubsub: MyApp.PubSub,
              topic: "things:all",
              event_name: :something_happened
            ]
          ]

        def broadcast(record) do
          payload = %{id: record.id, foo: record.foo}
          safe_broadcast({event_name(), payload})
        end
      end

  ## Options

    * `:pubsub` (required) — the `Phoenix.PubSub` module to broadcast through.
    * `:topic` (required) — either a string topic OR an `{Module, :function}`
      tuple resolved at broadcast time with the record as the single arg.
      Per-record routing is the foundation for per-wave / per-crucible
      topic variants without changing the call sites.
    * `:event_name` (optional) — atom subscribers receive in the wire-shape
      `{event_name, payload}`. Defaults to the underscored last segment
      of the module name (e.g. `EngagementClaimed` → `:engagement_claimed`).

  ## Generated helpers

  Injected into the implementor module:

    * `topic/0` — static topic string (raises if `:topic` is an MFA tuple).
    * `topic/1` — resolves the topic for a given record (calls the MFA
      tuple or returns the static string).
    * `event_name/0` — the wire-event atom.
    * `safe_broadcast/1` — wraps `Phoenix.PubSub.broadcast/3` with rescue +
      `[:ash_dispatch, :custom_topic, :broadcast_failure]` telemetry +
      log. Always returns `:ok`. Takes the `{event_name, payload}` tuple.
    * `safe_broadcast/2` — same as `/1` but takes an explicit record for
      per-record topic resolution: `safe_broadcast(record, {evt, payload})`.

  All generated functions are `defoverridable` — implementors can replace
  any of them without losing the others' compile-time wiring.

  ## Why this lives next to `AshDispatch.Event`

  The `use` call is the same module name; the heavyweight DSL path
  (channels / recipients / content) remains the default when no
  `:transports` option is passed. The split happens at macro-expansion
  time: when `transports: [custom_topic: ...]` is present, this module's
  `inject/1` returns extra quoted AST appended to the existing DSL
  setup; when absent, behaviour is identical to pre-extension.
  """

  @doc false
  def inject(opts) do
    pubsub = Keyword.fetch!(opts, :pubsub)
    topic_spec = Keyword.fetch!(opts, :topic)
    event_name_override = Keyword.get(opts, :event_name)

    # Macro-time validation: topic must be a literal string OR a 2-tuple
    # `{Module, :function}`. Runtime values aren't supported because the
    # spec is captured at compile time for fast access.
    validate_topic_spec!(topic_spec)

    quote do
      require Logger

      @custom_topic_pubsub unquote(pubsub)
      @custom_topic_spec unquote(Macro.escape(topic_spec))
      @custom_topic_event_name unquote(event_name_override) ||
                                 AshDispatch.Event.CustomTopic.derive_event_name(__MODULE__)

      @doc "Static PubSub topic this event publishes to. Raises if topic is per-record."
      @spec topic() :: String.t()
      def topic do
        case @custom_topic_spec do
          topic when is_binary(topic) ->
            topic

          {_mod, _fun} ->
            raise ArgumentError,
                  "#{inspect(__MODULE__)} uses a per-record topic; call topic/1 with the record"
        end
      end

      @doc "Topic resolved for a given record (handles static + per-record MFA)."
      @spec topic(term()) :: String.t()
      def topic(record) do
        case @custom_topic_spec do
          topic when is_binary(topic) -> topic
          {mod, fun} -> apply(mod, fun, [record])
        end
      end

      @doc "Wire-event atom subscribers receive in `{event_name, payload}`."
      @spec event_name() :: atom()
      def event_name, do: @custom_topic_event_name

      @doc """
      Broadcast a `{event_name, payload}` tuple to the static topic.

      Failures are caught + logged + telemetry-emitted as
      `[:ash_dispatch, :custom_topic, :broadcast_failure]`. Always
      returns `:ok` — broadcasts are notification side-channels, not
      sources of truth.
      """
      @spec safe_broadcast({atom(), term()}) :: :ok
      def safe_broadcast({_evt, _payload} = message) do
        AshDispatch.Event.CustomTopic.do_broadcast(
          __MODULE__,
          @custom_topic_pubsub,
          topic(),
          message
        )
      end

      @doc "Broadcast for per-record topic routing — resolves topic from record."
      @spec safe_broadcast(term(), {atom(), term()}) :: :ok
      def safe_broadcast(record, {_evt, _payload} = message) do
        AshDispatch.Event.CustomTopic.do_broadcast(
          __MODULE__,
          @custom_topic_pubsub,
          topic(record),
          message
        )
      end

      defoverridable topic: 0, topic: 1, event_name: 0, safe_broadcast: 1, safe_broadcast: 2
    end
  end

  @doc false
  def do_broadcast(module, pubsub, topic, {event_name, _payload} = message) do
    Phoenix.PubSub.broadcast(pubsub, topic, message)
    :ok
  rescue
    e ->
      require Logger

      Logger.warning(
        "[#{inspect(module)}] custom_topic broadcast failed: #{Exception.message(e)}"
      )

      :telemetry.execute(
        [:ash_dispatch, :custom_topic, :broadcast_failure],
        %{count: 1},
        %{module: module, event: event_name, topic: topic, error: inspect(e)}
      )

      :ok
  end

  @doc false
  def derive_event_name(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_atom()
  end

  defp validate_topic_spec!(topic) when is_binary(topic), do: :ok
  defp validate_topic_spec!({mod, fun}) when is_atom(mod) and is_atom(fun), do: :ok

  defp validate_topic_spec!(other) do
    raise ArgumentError, """
    Invalid :topic for AshDispatch.Event custom_topic transport.

    Expected a string topic OR a `{Module, :function}` 2-tuple for
    per-record routing. Got: #{inspect(other)}
    """
  end
end
