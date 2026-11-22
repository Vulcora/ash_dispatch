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

  `tenant:` is the tenant the write happens in, so a per-tenant receipt lands
  in the right schema — and it is also KEPT as an attribute, so a host with
  public receipts and `tenant_column: true` gets the column filled. The value
  is normalised through the library's own tenant key, so it matches what the
  dispatcher writes for the same tenant.

  The outcome is checked before anything is created, so a bad call leaves no
  `:pending` row behind.
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
        # The outcome is checked BEFORE the row is created. A `record/3` called
        # with something that is not an outcome used to leave a `:pending`
        # receipt behind — a row claiming a delivery is in flight that nothing
        # will ever settle, which is worse than the missing receipt it was
        # called to prevent.
        with :ok <- validate_outcome(outcome),
             {:ok, receipt} <- create(resource, attrs, tenant_of(attrs)) do
          settle(receipt, outcome, opts)
        end
    end
  end

  defp validate_outcome({:sent, _response}), do: :ok
  defp validate_outcome({skipped, _reason}) when skipped in [:skip, :skipped], do: :ok
  defp validate_outcome({:error, _reason}), do: :ok

  defp validate_outcome(outcome) do
    Logger.warning(
      "AshDispatch.Receipts.record/2: #{inspect(outcome)} is not an outcome; nothing recorded"
    )

    {:error, {:unknown_outcome, outcome}}
  end

  # The tenant is read, NOT popped. `tenant_column: true` makes `:tenant` an
  # accepted attribute of `:create`, and popping it meant a recorded receipt
  # was written with a NULL tenant on exactly the configuration the column
  # exists for. It is normalised through the library's own key so the value
  # matches what the dispatcher writes for the same tenant.
  defp tenant_of(attrs), do: Map.get(attrs, :tenant)

  defp create(resource, attrs, tenant) do
    attrs = normalise_tenant(attrs, tenant)

    resource
    # Everything the resource's `:create` does not accept is dropped. A host
    # recording into a receipt resource of its own should not have to discover
    # which of our keys it happens to have — and `:tenant` is in that list
    # only with `tenant_column: true`, so it survives there and is dropped
    # everywhere else.
    |> Ash.Changeset.for_create(:create, attrs, skip_unknown_inputs: :*)
    |> Tenancy.set(tenant)
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, receipt} -> {:ok, Tenancy.remember(receipt, tenant)}
      {:error, reason} -> {:error, reason}
    end
  end

  # An explicit `tenant: nil` is DELETED rather than passed on: Ash applies an
  # attribute's default only when the input is ABSENT, so a literal nil
  # defeats the default of a host's own `tenant` attribute — the same trap
  # `Dispatcher.build_receipt/4` has a `maybe_put/3` for.
  defp normalise_tenant(attrs, nil), do: Map.delete(attrs, :tenant)

  defp normalise_tenant(attrs, tenant) do
    case AshDispatch.Context.tenant_key(tenant) do
      key when is_binary(key) -> Map.put(attrs, :tenant, key)
      _ -> Map.delete(attrs, :tenant)
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
  rescue
    # The same rescue the other two outcomes have. `skip/2` does not raise on a
    # refused transition, but a receipt resource of a host's own can raise in
    # a validation or a change of its own, and `record/3` answering a tuple is
    # the contract.
    error -> {:error, Exception.message(error)}
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

  defp message(reason) when is_binary(reason), do: reason
  defp message(reason), do: AshDispatch.Log.reason(reason)
end
