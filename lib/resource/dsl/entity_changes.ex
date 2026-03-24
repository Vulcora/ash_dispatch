defmodule AshDispatch.Resource.Dsl.EntityChanges do
  @moduledoc """
  Data structure for entity_changes configuration in the dispatch section.

  When `entity_changes true` is set, the resource's CRUD events are broadcast
  as `entity_change` and `entity_created` channel events, enabling real-time
  UI updates (entity snapshots, toast notifications, etc.).

  ## Fields

  - `:enabled` - Whether entity change broadcasting is enabled
  - `:trigger_on` - Optional list of actions to restrict broadcasting to.
    Defaults to all create/update/destroy actions.
  - `:label_fields` - Fields to use for entity label. Defaults to `[:title, :name]`.
  - `:status_field` - Field for entity status. Auto-detected from AshStateMachine if present.
  """

  defstruct [
    :trigger_on,
    :status_field,
    enabled: false,
    label_fields: [:title, :name],
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{
          enabled: boolean(),
          trigger_on: [atom()] | nil,
          label_fields: [atom()],
          status_field: atom() | nil
        }
end
