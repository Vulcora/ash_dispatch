defmodule AshDispatch.Dsl.CounterBroadcast do
  @moduledoc """
  DSL entity struct for counter broadcast configurations.
  """

  defstruct [
    :counter_names,
    :on_transport,
    :on_audience,
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{
          counter_names: [atom()],
          on_transport: [atom()] | nil,
          on_audience: [atom()] | nil
        }
end
