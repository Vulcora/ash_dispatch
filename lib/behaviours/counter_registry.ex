defmodule AshDispatch.Behaviours.CounterRegistry do
  @moduledoc """
  Behaviour for defining and executing counter queries.

  This behaviour provides the foundation for a future Ash DSL extension that
  will allow declaring counters directly in resources.

  ## Current Usage (Function-Based)

  Applications implement this behaviour to define their counters:

      defmodule MyApp.CounterRegistry do
        @behaviour AshDispatch.Behaviours.CounterRegistry

        @impl true
        def get(counter_name) do
          Enum.find(counters(), &(&1.name == counter_name))
        end

        @impl true
        def list, do: counters()

        @impl true
        def execute_query(counter_name, :user, user_id: user_id) do
          counter = get(counter_name)
          if counter && counter.user_query do
            query = counter.user_query.(user_id: user_id)
            query |> Ash.count(authorize?: false) |> elem(1)
          else
            0
          end
        end

        def execute_query(counter_name, :admin, _opts) do
          counter = get(counter_name)
          if counter && counter.admin_query do
            query = counter.admin_query.()
            query |> Ash.count(authorize?: false) |> elem(1)
          else
            0
          end
        end

        defp counters do
          [
            %{
              name: :pending_orders,
              broadcast_type: :user_and_admin,
              query_keys: ["orders"],
              user_query: fn opts ->
                user_id = Keyword.fetch!(opts, :user_id)
                MyApp.Orders.Order
                |> Ash.Query.filter(user_id == ^user_id and status == :pending)
              end,
              admin_query: fn ->
                MyApp.Orders.Order
                |> Ash.Query.filter(status == :pending)
              end
            }
          ]
        end
      end

  ## Future: DSL Extension

  This will eventually be replaced with a declarative DSL:

      defmodule MyApp.Orders.Order do
        use Ash.Resource

        counters do
          counter :pending_orders do
            description "Count of pending orders"
            broadcast :user_and_admin
            invalidates ["orders"]

            user_scope do
              filter user_id == ^arg(:user_id)
              filter status == :pending
            end

            admin_scope do
              filter status == :pending
            end
          end
        end
      end

  ## Counter Definition

  A counter definition is a map with:

  - `:name` - Counter identifier (atom)
  - `:broadcast_type` - One of `:user_only`, `:user_and_admin`, `:admin_only`
  - `:query_keys` - List of query keys for frontend cache invalidation
  - `:user_query` - Function that returns Ash.Query for user-specific count
  - `:admin_query` - Function that returns Ash.Query for admin total count

  ## Configuration

      config :ash_dispatch,
        counter_registry: MyApp.CounterRegistry
  """

  @type counter_name :: atom()
  @type broadcast_type :: :user_only | :user_and_admin | :admin_only
  @type scope :: :user | :admin

  @type counter_definition :: %{
          name: counter_name(),
          broadcast_type: broadcast_type(),
          query_keys: [String.t()],
          user_query: (keyword() -> Ash.Query.t()) | nil,
          admin_query: (-> Ash.Query.t()) | nil
        }

  @doc """
  Get a counter definition by name.

  Returns `nil` if counter not found.
  """
  @callback get(counter_name()) :: counter_definition() | nil

  @doc """
  List all registered counters.
  """
  @callback list() :: [counter_definition()]

  @doc """
  Execute a counter query and return the count.

  ## Scopes

  - `:user` - Execute user-specific query with `user_id` in opts
  - `:admin` - Execute admin total query

  ## Examples

      execute_query(:pending_orders, :user, user_id: "user-uuid")
      #=> 5

      execute_query(:pending_orders, :admin)
      #=> 42
  """
  @callback execute_query(counter_name(), scope(), opts :: keyword()) :: non_neg_integer()
end
