defmodule AshDispatch.Resource.Dsl.Counter do
  @moduledoc """
  Data structure representing a counter definition from the DSL.

  This is the target of the `counter` entity in the `counters` section.

  ## Fields

  - `:name` - Unique counter identifier in DSL (atom, e.g., `:pending_orders_counter`)
  - `:trigger_on` - List of action names that trigger this counter
  - `:counter_name` - Counter name to broadcast (atom)
  - `:resource` - Ash resource module to query for counting (optional, defaults to current resource)
  - `:query_filter` - Ash.Query filter expression to count items
  - `:audience` - Audience type (`:user`, `:admin`, or `:system`)
  - `:invalidates` - Frontend query keys to invalidate (list of strings)
  - `:user_id_path` - Relationship path to user_id (e.g., `[:cart, :user_id]` for nested relationships)
  - `:filter_by_record` - Filter counted resource by triggering record field (e.g., `[field: :cart_id]`)
  - `:group` - Counter group for TypeScript generation (e.g., `:orders`, `:tickets`)
  - `:global?` - Whether this is a global counter (bypasses policies, no user scoping)
  - `:aggregate` - Ash aggregate name to use instead of query_filter
  """

  defstruct [
    :name,
    :trigger_on,
    :counter_name,
    :resource,
    :query_filter,
    :audience,
    :invalidates,
    :user_id_path,
    :filter_by_record,
    :group,
    :aggregate,
    global?: false,
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{
          name: atom(),
          trigger_on: [atom()],
          counter_name: atom(),
          resource: module() | nil,
          query_filter: any(),
          audience: :user | :admin | :system,
          invalidates: [String.t()],
          user_id_path: [atom()] | nil,
          filter_by_record: keyword() | map() | nil,
          group: atom() | nil,
          global?: boolean(),
          aggregate: atom() | nil
        }
end
