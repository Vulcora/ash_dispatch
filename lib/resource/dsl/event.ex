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
    :data_key,
    :template_path,
    load: [],
    channels: [],
    content: %{},
    metadata: %{},
    recipient: %{},
    recipient_filter: %{},
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{
          name: atom(),
          trigger_on: atom() | [atom()],
          module: module() | nil,
          event_id: String.t() | nil,
          domain: atom() | nil,
          data_key: atom() | nil,
          template_path: String.t() | nil,
          load: [atom() | {atom(), any()}],
          channels: [AshDispatch.Dsl.Channel.t()],
          content: map(),
          metadata: map(),
          recipient: map(),
          recipient_filter: map(),
          __spark_metadata__: any()
        }
end
