defmodule AshDispatch.Dsl.Channel do
  @moduledoc """
  DSL entity struct for channel definitions.

  This is used by Spark to store channel configurations from the DSL.
  At runtime, these are converted to `AshDispatch.Channel` structs.
  """

  defstruct [
    :transport,
    :audience,
    :variant,
    :webhook_url,
    :deduplicate_group,
    __spark_metadata__: nil,
    time: {:in, 0},
    policy: :always,
    optional: false,
    content: %{},
    metadata: %{},
    opts: %{},
    counters: [],
    load: []
  ]

  @type t :: %__MODULE__{
          transport: atom(),
          audience: atom(),
          time: any(),
          policy: atom(),
          variant: atom() | nil,
          webhook_url: String.t() | nil,
          deduplicate_group: atom() | nil,
          optional: boolean(),
          content: map(),
          metadata: map(),
          opts: map(),
          counters: [atom()],
          load: [atom() | {atom(), any()}]
        }
end
