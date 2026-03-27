defmodule AshDispatch.Resource.Transformers.InjectEntityNotifier do
  @moduledoc """
  Transformer that auto-injects the host app's EntityNotifier into any resource
  that declares `entity_changes(true)`.

  This eliminates the need to manually add `simple_notifiers: [...]` on each
  entity resource — the dispatch extension handles it automatically.

  ## Configuration

  Set the notifier module in your AshDispatch config:

      config :ash_dispatch, entity_notifier: MyApp.Notifiers.EntityNotifier

  If not configured, this transformer is a no-op.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def after?(AshDispatch.Resource.Transformers.ValidateEvents), do: true

  @impl true
  def after?(_), do: false

  @impl true
  def transform(dsl_state) do
    notifier_module = Application.get_env(:ash_dispatch, :entity_notifier)

    if notifier_module && entity_changes_enabled?(dsl_state) do
      existing = Transformer.get_persisted(dsl_state, :simple_notifiers) || []

      if notifier_module in existing do
        {:ok, dsl_state}
      else
        {:ok, Transformer.persist(dsl_state, :simple_notifiers, [notifier_module | existing])}
      end
    else
      {:ok, dsl_state}
    end
  end

  defp entity_changes_enabled?(dsl_state) do
    dsl_state
    |> Transformer.get_entities([:dispatch])
    |> Enum.any?(fn
      %AshDispatch.Resource.Dsl.EntityChanges{enabled: true} -> true
      _ -> false
    end)
  end
end
