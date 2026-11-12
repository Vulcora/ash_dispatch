defmodule AshDispatch.Transports.Push do
  use AshDispatch.Transport, atom: :push, skip_receipt?: false

  @moduledoc """
  Web Push transport — delegates to a consumer-configured backend.

  Configure a backend module in your app config and ash_dispatch will
  call its `deliver/4` callback every time an event with a `:push`
  channel fires:

      config :ash_dispatch, :push_backend, MyApp.Push

  The backend module must implement `AshDispatch.PushBackend`:

      defmodule MyApp.Push do
        @behaviour AshDispatch.PushBackend

        @impl true
        def deliver(receipt, context, channel, event_config) do
          # look up the user's subscriptions, encrypt per RFC 8291,
          # POST to each endpoint, prune the ones answering 404/410,
          # then mark the receipt :sent / :skipped / :failed.
        end
      end

  When no backend is configured the receipt is marked `:skipped` with
  `error_message: "transport_not_implemented"` — same shape as the SMS
  transport, so an app can declare `:push` channels before the backend
  exists without failing events.

  ## Declare push channels as `optional: true`

  Push is opt-in twice over: the browser must grant permission *and*
  the user must have visited on a device that supports it. A `:push`
  channel that is not `optional: true` turns "this user never allowed
  notifications" into a delivery failure. Mark it optional and let the
  recipient resolver soft-skip, the same way SMS soft-skips a recipient
  without a phone number.
  """

  require Logger

  alias AshDispatch.Config
  alias AshDispatch.Delivery
  alias AshDispatch.Transports.Preferences

  def deliver(receipt, context, channel, event_config) do
    Preferences.with_consent(receipt, context, channel, event_config, fn ->
      do_deliver(receipt, context, channel, event_config)
    end)
  end

  # The gate sits ABOVE the backend on purpose: a consumer's own backend
  # cannot be expected to know about preferences, and asking it to would put
  # the same eight lines in every app that wires SMS.
  defp do_deliver(receipt, context, channel, event_config) do
    # A missing backend still wins over the delivery mode, as it did before:
    # "no backend is configured" says more about the state of the host than
    # "this host does not send", and a host without one behaves exactly as it
    # does today.
    case {Config.push_backend(), Delivery.mode_verdict(receipt)} do
      {nil, _verdict} ->
        Logger.info("Push transport not yet implemented (no :push_backend configured), skipping")

        {:ok, AshDispatch.ReceiptStatus.mark_skipped(receipt, "transport_not_implemented")}

      # Push delivers synchronously, so this is the moment of sending: a host
      # on `:blocked`, `:dry_run` or an allow-list never reaches the backend.
      {_backend, {:skip, reason}} ->
        {:ok, Delivery.hold(receipt, reason)}

      {backend, :send} when is_atom(backend) ->
        backend.deliver(receipt, context, channel, event_config)
    end
  end
end
