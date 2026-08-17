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

  def deliver(receipt, context, channel, event_config) do
    case Config.push_backend() do
      nil ->
        Logger.info("Push transport not yet implemented (no :push_backend configured), skipping")

        receipt
        |> Ash.Changeset.for_update(:skip, %{error_message: "transport_not_implemented"})
        |> Ash.update!(authorize?: false)
        |> then(&{:ok, &1})

      backend when is_atom(backend) ->
        backend.deliver(receipt, context, channel, event_config)
    end
  end
end
