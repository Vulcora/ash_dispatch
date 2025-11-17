defmodule AshDispatch.Dsl.Transformers.InferEventId do
  @moduledoc """
  Transformer that infers the event ID from the module name if not explicitly set.

  ## Example

      defmodule MyApp.Events.Orders.Created do
        use AshDispatch.Event

        dispatch do
          # No id specified
        end
      end

      # Transformer infers id as "created" from module name
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def transform(dsl_state) do
    # Check if id is already set
    case Transformer.get_option(dsl_state, [:dispatch], :id) do
      nil ->
        # For now, just leave it nil
        # The event module's id/0 function will handle inference
        {:ok, dsl_state}

      _id ->
        # ID already set, nothing to do
        {:ok, dsl_state}
    end
  end
end
