defmodule AshDispatch.Transport.Retry do
  @moduledoc """
  Hur ett misslyckat kvitto görs om, per transport.

  Finns för att svaret bodde på två ställen: `Workers.RetryFailedDeliveries`
  (cronen) och `Changes.EnqueueRetryJob` (knapparna `:retry`, `:reopen` och
  `:send_now`). Båda hade samma tre grenar, och en transport som lades till i
  den ena men inte den andra fick ett omförsök från cronen men inte från
  admin-gränssnittet — eller tvärtom. Nu finns listan en gång.

  ## Strategierna

  - `{:worker, modul}` — köa ett Oban-jobb. Modulen ska ha
    `new_for_receipt/1`.
  - `{:direct, modul}` — leveransen är synkron och görs om direkt. Modulen ska
    ha `retry_from_receipt/1`.
  - `:unsupported` — transporten har ingen väg tillbaka.

  ## `:unsupported` är inte harmlöst

  Ett kvitto vars transport saknar strategi går ändå igenom `:retry`, vilket
  räknar upp `retry_count`, och landar sedan i `:failed` igen när köandet
  misslyckas. Fem cronvarv senare är det `:failed_permanent` — utan att ha
  skickats om en enda gång. Det var exakt vad som hände `:sms` fram till
  0.6.11.
  """

  @doc """
  Strategin för en transport.
  """
  @spec strategy(atom()) :: {:worker, module()} | {:direct, module()} | :unsupported
  def strategy(:email), do: {:worker, AshDispatch.Workers.SendEmail}
  def strategy(:sms), do: {:worker, AshDispatch.Workers.SendSMS}
  def strategy(:in_app), do: {:direct, AshDispatch.Transports.InApp}
  def strategy(_transport), do: :unsupported

  @doc """
  Sant om transporten går att göra om.
  """
  @spec retryable?(atom()) :: boolean()
  def retryable?(transport), do: strategy(transport) != :unsupported

  @doc """
  Transporterna som går att göra om, sorterade. Främst för felmeddelanden och
  tester.
  """
  @spec retryable_transports() :: [atom()]
  def retryable_transports do
    AshDispatch.Transport.Registry.receipted_atoms()
    |> Enum.filter(&retryable?/1)
  end

  @doc """
  Kör om ett kvitto enligt sin transports strategi.

  Bara för kö-vägen. Den direkta vägen (`{:direct, _}`) hanteras av
  anroparen, eftersom cronen och knapparna behöver olika svar tillbaka:
  cronen vill veta att kvittot redan är färdighanterat och hoppa över sin egen
  statusuppdatering, knapparna vill ha ett jobb-id att spara.
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
