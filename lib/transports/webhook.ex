defmodule AshDispatch.Transports.Webhook do
  use AshDispatch.Transport, atom: :webhook, skip_receipt?: false

  @moduledoc """
  Generic webhook transport.

  Sends HTTP POST requests to configured webhooks (async via Oban).

  ## Configuration

  Requires `webhook_url` in channel:

      channel = %Channel{
        transport: :webhook,
        audience: :external,
        webhook_url: "https://api.example.com/webhooks/events"
      }

  ## Status

  🚧 **Not yet implemented** - Returns {:ok, receipt} with status :skipped
  """

  require Logger

  def deliver(receipt, _context, _channel, _event_config) do
    Logger.info("Webhook transport not yet implemented, skipping")

    updated_receipt =
      receipt
      |> Ash.Changeset.for_update(:skip, %{error_message: "transport_not_implemented"})
      |> Ash.update!()

    {:ok, updated_receipt}
  end
end
