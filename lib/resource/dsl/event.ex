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
    :include_actor_as,
    :locale_from,
    priority: :standard,
    load: [],
    channels: [],
    content: %{},
    metadata: %{},
    recipient: %{},
    recipient_filter: %{},
    invalidates: [],
    locales: [],
    __spark_metadata__: nil
  ]

  @type priority :: :urgent | :standard | :informational

  @type t :: %__MODULE__{
          name: atom(),
          trigger_on: atom() | [atom()],
          module: module() | nil,
          event_id: String.t() | nil,
          domain: atom() | nil,
          data_key: atom() | nil,
          template_path: String.t() | nil,
          include_actor_as: atom() | nil,
          locale_from: atom() | nil,
          priority: priority(),
          load: [atom() | {atom(), any()}],
          channels: [AshDispatch.Dsl.Channel.t()],
          content: map(),
          metadata: map(),
          recipient: map(),
          recipient_filter: map(),
          invalidates: [String.t()],
          locales: [String.t()],
          __spark_metadata__: any()
        }
end
