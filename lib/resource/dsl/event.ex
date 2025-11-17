defmodule AshDispatch.Resource.Dsl.Event do
  @moduledoc """
  DSL entity struct for event definitions in resources.

  This struct holds the complete configuration for an event defined in a resource.
  """

  defstruct [
    :name,
    :trigger_on,
    :module,
    :event_id,
    :domain,
    load: [],
    channels: [],
    content: %{},
    metadata: %{},
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{
          name: atom(),
          trigger_on: atom() | [atom()],
          module: module() | nil,
          event_id: String.t() | nil,
          domain: atom() | nil,
          load: [atom()],
          channels: [AshDispatch.Dsl.Channel.t()],
          content: map(),
          metadata: map(),
          __spark_metadata__: any()
        }
end
