defmodule AshDispatch.Transport.Registry do
  @moduledoc """
  Compile-time aggregator over `AshDispatch.Transport` implementations.

  The dispatcher routes by `channel.transport` atom (`:oban`, `:email`,
  …); this module owns the `atom => module` mapping and the
  `skip_receipt?` lookup. Each known transport is listed below in
  `@transports`; adding one is a single-line addition + a new transport
  file that `use`s `AshDispatch.Transport`.

  ## Why compile-time

  At runtime, `Dispatcher.dispatch_to_transport/4` is hot-path — every
  event fire passes through it. A compile-time `Map.new` from the
  module list avoids any runtime introspection cost. The Map is
  module-attribute-frozen; lookups are constant time.

  ## Why hardcoded module list (not auto-discovery)

  We could walk `:application.get_key(:ash_dispatch, :modules)` and
  filter implementers of the behaviour, but:

    1. Boot order matters — the dispatcher could be invoked before
       transport modules finish loading, producing a partial registry.
    2. AshDispatch is a library; its consumers can't add their own
       transports today (only the 8 listed here). If that changes,
       this module evolves to a Spark DSL-driven registry.

  Today's static list is the right shape for the actual consumer set.
  """

  @transports [
    AshDispatch.Transports.InApp,
    AshDispatch.Transports.Email,
    AshDispatch.Transports.Discord,
    AshDispatch.Transports.Slack,
    AshDispatch.Transports.SMS,
    AshDispatch.Transports.Webhook,
    AshDispatch.Transports.Broadcast,
    AshDispatch.Transports.Oban
  ]

  # Compile-time map. Each transport's `transport_atom/0` must be a
  # compile-time constant for this to work, which the `use` macro
  # guarantees (the atom is interpolated into the function body).
  @atom_to_module Map.new(@transports, fn module -> {module.transport_atom(), module} end)

  @doc "All registered transport modules."
  @spec all() :: [module()]
  def all, do: @transports

  @doc "All registered transport atoms."
  @spec atoms() :: [atom()]
  def atoms, do: Map.keys(@atom_to_module)

  @doc """
  Find the module that handles a transport atom.

  Returns `{:ok, module}` or `:error` for unknown atoms. Callers
  should `:error`-handle by logging + skipping the receipt (matches
  the pre-F1 case-fallthrough behaviour).
  """
  @spec module_for(atom()) :: {:ok, module()} | :error
  def module_for(atom) when is_atom(atom) do
    case Map.fetch(@atom_to_module, atom) do
      {:ok, _} = ok -> ok
      :error -> :error
    end
  end

  @doc """
  Whether the transport skips `DeliveryReceipt` creation. Returns
  `false` for unknown atoms (the safe default — produce a receipt
  so the audit trail isn't silent).
  """
  @spec skip_receipt?(atom()) :: boolean()
  def skip_receipt?(atom) when is_atom(atom) do
    case module_for(atom) do
      {:ok, module} -> module.skip_receipt?()
      :error -> false
    end
  end

  @doc """
  Required event-metadata keys for the transport (F4). Returns `[]`
  for unknown atoms — `ValidateChannels` will already have raised
  on the unknown transport itself.
  """
  @spec required_event_metadata_keys(atom()) :: [atom()]
  def required_event_metadata_keys(atom) when is_atom(atom) do
    case module_for(atom) do
      {:ok, module} ->
        if function_exported?(module, :required_event_metadata_keys, 0) do
          module.required_event_metadata_keys()
        else
          []
        end

      :error ->
        []
    end
  end
end
