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
  - `:audience` - Audience atom (any atom configured in `:ash_dispatch, :audiences`)
  - `:invalidates` - Frontend query keys to invalidate (list of strings)
  - `:user_id_path` - Relationship path to user_id (e.g., `[:cart, :user_id]` for nested relationships)
  - `:scope` - Ash expression for scoping queries (e.g., `expr(user_id == ^actor(:id))`)
  - `:filter_by_record` - Filter counted resource by triggering record field (e.g., `[field: :cart_id]`)
  - `:group` - Counter group for TypeScript generation (e.g., `:orders`, `:tickets`)
  - `:authorize?` - Whether to use Ash authorization (default: true)
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
    :scope,
    :filter_by_record,
    :group,
    :aggregate,
    authorize?: true,
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{
          name: atom(),
          trigger_on: [atom()],
          counter_name: atom(),
          resource: module() | nil,
          query_filter: any(),
          audience: atom(),
          invalidates: [String.t()],
          user_id_path: [atom()] | nil,
          scope: Ash.Expr.t() | nil,
          filter_by_record: keyword() | map() | nil,
          group: atom() | nil,
          authorize?: boolean(),
          aggregate: atom() | nil
        }
end
