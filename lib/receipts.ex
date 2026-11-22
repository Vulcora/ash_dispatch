defmodule AshDispatch.Receipts do
  @moduledoc """
  A receipt for something this library did not send.

  Every installation has a send that does not go through the dispatcher: a
  provider's own SDK, a one-off script, a confirmation written before the
  library arrived, a transport the library has no backend for. Those sends
  leave no receipt, and a missing receipt is not a neutral gap — it reads as
  "nothing was sent". One installation measured ninety-two of ninety-six cases
  where a recipient had been reached and no letter existed to prove it; the
  silence had become data, and the data was wrong.

  `record/2` writes the receipt without sending anything:

      AshDispatch.Receipts.record(
        %{
          event_id: "bookings.reminder",
          transport: :sms,
          audience: :user,
          recipient: "+46701234567",
          user_id: user.id,
          content: %{message: text},
          source_type: "Booking",
          source_id: booking.id
        },
        {:sent, %{id: provider_message_id}}
      )

  ## The outcome

  - `{:sent, response}` — it reached the provider. The receipt is `:sent`, with
    `provider_id` taken from `response[:id]` (or `response["id"]`) and the whole
    response stored, so the delivery webhook can find it by provider id exactly
    as it finds the library's own.
  - `{:skipped, reason}` — deliberately not sent. The receipt is `:skipped`
    with the reason, and `AshDispatch.Reason.of/1` classifies it (`:other`
    unless the reason is one of the library's own).
  - `{:error, reason}` — it failed. The receipt is `:failed_permanent`, NOT
    `:failed`: a `:failed` receipt is what `RetryFailedDeliveries` picks up,
    and it would re-enqueue a send of the library's own rendering for a letter
    the library never composed. Pass `retry?: true` if the library should take
    it over, having checked that the receipt holds a letter it could actually
    send.

  Returns `{:ok, receipt}` or `{:error, reason}`. Nothing is delivered, no job
  is enqueued, and no notification is written.

  ## What goes in the attributes

  Whatever the configured receipt resource's `:create` accepts; anything else
  is dropped rather than raising, so a receipt resource of a host's own does
  not have to grow a column to be recorded into. `event_id` and `transport`
  are the two that make the row findable, and `source_type`/`source_id` are
  what a history page groups by.

  `tenant:` is read out of the attributes and used as the tenant for the
  write, so a per-tenant receipt lands in the right schema.
  """

  alias AshDispatch.Config
  alias AshDispatch.ReceiptStatus
  alias AshDispatch.Tenancy

  require Logger

  @type outcome ::
          {:sent, map()}
          | {:skipped, String.t()}
          | {:error, term()}

  @doc """
  Writes a receipt for a delivery that happened outside the dispatcher.

  See the moduledoc. `opts` takes `retry?: true` to record a failure as
  `:failed` (which the retry sweep will pick up) rather than
  `:failed_permanent`.
  """
  @spec record(map(), outcome(), keyword()) :: {:ok, struct()} | {:error, term()}
  def record(attrs, outcome, opts \\ []) when is_map(attrs) do
    case Config.delivery_receipt_resource() do
      nil ->
        {:error, :no_delivery_receipt_resource}

      resource ->
        {tenant, attrs} = Map.pop(attrs, :tenant)

        with {:ok, receipt} <- create(resource, attrs, tenant) do
          settle(receipt, outcome, opts)
        end
    end
  end

  defp create(resource, attrs, tenant) do
    resource
    # Everything the resource's `:create` does not accept is dropped. A host
    # recording into a receipt resource of its own should not have to discover
    # which of our keys it happens to have.
    |> Ash.Changeset.for_create(:create, attrs, skip_unknown_inputs: :*)
    |> Tenancy.set(tenant)
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, receipt} -> {:ok, Tenancy.remember(receipt, tenant)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp settle(receipt, {:sent, response}, _opts) do
    response = if is_map(response), do: response, else: %{}

    {:ok, ReceiptStatus.mark_sent(receipt, response)}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp settle(receipt, {skipped, reason}, _opts) when skipped in [:skip, :skipped] do
    ReceiptStatus.skip(receipt, message(reason))
  end

  defp settle(receipt, {:error, reason}, opts) do
    if Keyword.get(opts, :retry?, false) do
      {:ok, ReceiptStatus.mark_failed(receipt, message(reason))}
    else
      {:ok, ReceiptStatus.refuse(receipt, message(reason))}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp settle(receipt, outcome, _opts) do
    Logger.warning(
      "AshDispatch.Receipts.record/2: #{inspect(outcome)} is not an outcome; " <>
        "receipt #{inspect(Map.get(receipt, :id))} left pending"
    )

    {:error, {:unknown_outcome, outcome}}
  end

  defp message(reason) when is_binary(reason), do: reason
  defp message(reason), do: AshDispatch.Log.reason(reason)
end
