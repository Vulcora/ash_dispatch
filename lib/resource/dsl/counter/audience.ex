defmodule AshDispatch.Resource.Dsl.Counter.Audience do
  @moduledoc """
  Data structure representing a counter audience (broadcast target).

  Audiences determine who receives counter broadcasts:
  - `:user` - Broadcast to specific user (with user-scoped query)
  - `:admin` - Broadcast to all admins (usually :total count)
  - `:system` - Broadcast globally (rare)

  ## Fields

  - `:type` - Audience type (`:user`, `:admin`, or `:system`)
  - `:query` - Either `:total` for full count, or filter expression for scoped count
  """

  defstruct [:type, :query]

  @type audience_type :: :user | :admin | :system
  @type query :: :total | any()

  @type t :: %__MODULE__{
          type: audience_type(),
          query: query()
        }
end
