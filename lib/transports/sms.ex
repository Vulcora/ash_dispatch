defmodule AshDispatch.Transports.SMS do
  @moduledoc """
  SMS transport.

  Sends SMS messages (async via Oban).

  ## Status

  🚧 **Not yet implemented** - Returns {:ok, receipt} with status :skipped
  """

  require Logger

  def deliver(receipt, _context, _channel, _event_config) do
    Logger.info("SMS transport not yet implemented, skipping")

    updated_receipt =
      receipt
      |> Ash.Changeset.for_update(:skip, %{error_message: "transport_not_implemented"})
      |> Ash.update!()

    {:ok, updated_receipt}
  end
end
