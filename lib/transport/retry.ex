defmodule AshDispatch.Transport.Retry do
  @moduledoc """
  How a failed receipt is retried, per transport.

  This exists because the answer used to live in two places:
  `Workers.RetryFailedDeliveries` (the cron) and `Changes.EnqueueRetryJob`
  (the `:retry`, `:reopen` and `:send_now` actions). Both carried the same
  three branches, so a transport added to one but not the other would be
  retried by the cron and not by the admin UI, or the other way round. The
  list now exists once.

  ## The strategies

  - `{:worker, module}` — enqueue an Oban job. The module must export
    `new_for_receipt/1`.
  - `{:direct, module}` — delivery is synchronous and retried inline. The
    module must export `retry_from_receipt/1`.
  - `:unsupported` — the transport has no way back.

  ## `:unsupported` is not harmless

  A receipt whose transport has no strategy still goes through `:retry`, which
  increments `retry_count`, and then lands back in `:failed` when the enqueue
  fails. Five cron passes later it is `:failed_permanent` — without having been
  resent even once. That is exactly what happened to `:sms` until 0.8.2.
  """

  @doc """
  The strategy for a transport.
  """
  @spec strategy(atom()) :: {:worker, module()} | {:direct, module()} | :unsupported
  def strategy(:email), do: {:worker, AshDispatch.Workers.SendEmail}
  def strategy(:sms), do: {:worker, AshDispatch.Workers.SendSMS}
  def strategy(:in_app), do: {:direct, AshDispatch.Transports.InApp}
  def strategy(_transport), do: :unsupported

  @doc """
  True if the transport can be retried.
  """
  @spec retryable?(atom()) :: boolean()
  def retryable?(transport), do: strategy(transport) != :unsupported

  @doc """
  The transports that can be retried. Mainly for error messages and tests.
  """
  @spec retryable_transports() :: [atom()]
  def retryable_transports do
    AshDispatch.Transport.Registry.receipted_atoms()
    |> Enum.filter(&retryable?/1)
  end

  @doc """
  Retries a receipt according to its transport's strategy.

  For the worker path only. The direct path (`{:direct, _}`) is handled by the
  caller, because the cron and the admin actions need different answers back:
  the cron wants to know the receipt is already fully handled so it can skip
  its own status update, the actions want a job id to store.
  """
  @spec enqueue_worker(struct()) :: {:ok, term()} | {:error, term()}
  def enqueue_worker(%{transport: transport} = receipt) do
    case strategy(transport) do
      {:worker, worker} ->
        receipt
        |> worker.new_for_receipt()
        |> Oban.insert()

      other ->
        {:error, {:not_a_worker_transport, other}}
    end
  end
end
