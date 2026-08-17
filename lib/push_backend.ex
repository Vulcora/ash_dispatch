defmodule AshDispatch.PushBackend do
  @moduledoc """
  Behaviour that a Web Push backend module implements. Configure a
  backend in your app config:

      config :ash_dispatch, :push_backend, MyApp.Push

  The transport (`AshDispatch.Transports.Push`) will call your backend's
  `deliver/4` whenever an event channel with `transport: :push` fires.

  ## Why the encryption lives in your app, not here

  Web Push (RFC 8291/8292) needs a VAPID keypair, an ECDH/HKDF
  encryption step and a per-endpoint HTTP POST to whatever push service
  the browser chose (FCM, Mozilla autopush, WNS…). Those are deployment
  concerns — key material, egress rules, retry budget — so ash_dispatch
  owns the routing and the audit trail and leaves the protocol to the
  consumer, exactly like `AshDispatch.SMSBackend`.

  ## Implementation contract

  - **One receipt fans out to many devices.** Unlike email or SMS there
    is no single address: a user has one subscription per browser and
    machine. Resolve them from `receipt.user_id` (or from
    `receipt.recipient` if your app stores a device token there) and
    send to each. The receipt represents the *event delivery*, not one
    device.
  - Read the payload from `receipt.content` — typically `:title`,
    `:body` and the URL your service worker should open on click.
    Keep it small: push services cap the encrypted payload (4 KB is the
    safe ceiling).
  - Update the receipt via Ash:
    - Success (at least one device accepted):
      `for_update(:mark_sent, %{provider_id: provider_id})`
    - No subscriptions at all: `for_update(:skip, %{error_message:
      "no_subscriptions"})` — a user who never granted permission is
      not a failure.
    - Failure: `for_update(:mark_failed, %{error_message: reason})`
  - Return `{:ok, updated_receipt}` or `{:error, reason}`.

  ## Pruning dead subscriptions

  Push endpoints expire silently. A push service answers `404` or `410
  Gone` once a subscription is dead, and it will keep answering that
  forever. Delete the subscription row on those two statuses — a backend
  that does not prune accumulates dead endpoints and spends its retry
  budget on browsers that no longer exist.

  Treat `429` and `5xx` as retryable instead; they are the push service
  throttling you, not the subscription being gone.
  """

  @callback deliver(
              receipt :: struct(),
              context :: AshDispatch.Context.t(),
              channel :: AshDispatch.Channel.t(),
              event_config :: map()
            ) :: {:ok, struct()} | {:error, term()}
end
