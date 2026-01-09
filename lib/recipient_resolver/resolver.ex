defmodule AshDispatch.RecipientResolver.Resolver do
  @moduledoc """
  Resolution logic for audience-based recipient lookup.

  This module implements the various resolution strategies:
  - `from_context` - Extract from event context
  - `query` - Query user resource with Ash filter
  - `path` - Follow relationship path on resource
  - `combine` - Union of other audiences
  - `resolve` - Custom resolver function
  """

  require Ash.Query
  require Logger

  @doc """
  Resolve recipients for an audience using the DSL configuration.
  """
  @spec resolve(module(), atom(), struct() | nil, map()) :: [map()]
  def resolve(resolver_module, audience, resource, context) do
    audiences = resolver_module.__audiences__()

    case find_audience(audiences, audience) do
      nil ->
        available = Enum.map(audiences, & &1.name)

        Logger.warning("""
        [AshDispatch.RecipientResolver] Unknown audience: #{inspect(audience)}
        Available audiences: #{inspect(available)}
        Resolver module: #{inspect(resolver_module)}
        """)

        []

      config ->
        users = resolve_by_strategy(config, resource, context, resolver_module)

        if config.raw do
          users
        else
          Enum.map(users, &resolver_module.to_recipient/1)
        end
    end
  end

  defp find_audience(audiences, name) do
    Enum.find(audiences, &(&1.name == name))
  end

  defp resolve_by_strategy(config, resource, context, resolver_module) do
    cond do
      config.from_context ->
        resolve_from_context(config.from_context, config.extract, context)

      config.query ->
        resolve_by_query(config.query, resolver_module.__user_resource__())

      config.path ->
        resolve_by_path(config.path, resource)

      config.combine ->
        resolve_combined(config.combine, resource, context, resolver_module)

      config.resolve ->
        resolve_custom(config.resolve, resource, context, resolver_module)

      true ->
        Logger.warning(
          "[AshDispatch.RecipientResolver] No resolution strategy for audience: #{inspect(config.name)}"
        )

        []
    end
  end

  # ===========================================================================
  # Resolution Strategies
  # ===========================================================================

  @doc """
  Extract recipients from context.data.

  ## Examples

      # Single key
      resolve_from_context(:user, nil, context)
      # => extracts context.data.user

      # Multiple keys (fallback chain)
      resolve_from_context([:user, :assignee], nil, context)
      # => tries :user first, falls back to :assignee

      # With extract option
      resolve_from_context([:meeting, :participants], :user, context)
      # => extracts context.data.meeting.participants, then .user from each
  """
  def resolve_from_context(key, extract, context) when is_atom(key) do
    case get_in_data(context, [key]) do
      nil ->
        []

      value when is_list(value) ->
        extract_from_collection(value, extract)

      value when is_struct(value) ->
        [value]

      _ ->
        []
    end
  end

  def resolve_from_context(keys, extract, context) when is_list(keys) do
    # Could be a path or a fallback chain
    # If all atoms, first try as a path, then as fallback chain
    result = get_in_data(context, keys)

    case result do
      nil ->
        # Try as fallback chain - find first non-nil single key
        Enum.find_value(keys, [], fn key ->
          case get_in_data(context, [key]) do
            nil -> nil
            value when is_struct(value) -> [value]
            value when is_list(value) -> extract_from_collection(value, extract)
            _ -> nil
          end
        end)

      value when is_list(value) ->
        extract_from_collection(value, extract)

      value when is_struct(value) ->
        [value]

      _ ->
        []
    end
  end

  defp get_in_data(context, keys) do
    data = Map.get(context, :data, %{})

    Enum.reduce_while(keys, data, fn key, acc ->
      case acc do
        %Ash.NotLoaded{} ->
          {:halt, nil}

        map when is_map(map) ->
          {:cont, Map.get(map, key)}

        _ ->
          {:halt, nil}
      end
    end)
  end

  defp extract_from_collection(items, nil), do: items

  defp extract_from_collection(items, extract_field) when is_list(items) do
    items
    |> Enum.map(&Map.get(&1, extract_field))
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Query user resource with Ash filter.

  ## Example

      resolve_by_query([role: :admin, is_active: true], MyApp.Accounts.User)
  """
  def resolve_by_query(filter, user_resource) when is_list(filter) do
    case user_resource
         |> Ash.Query.filter_input(filter)
         |> Ash.read(authorize?: false) do
      {:ok, users} ->
        users

      {:error, error} ->
        Logger.warning("[AshDispatch.RecipientResolver] Query failed: #{inspect(error)}")

        []
    end
  end

  @doc """
  Follow relationship path on resource.

  ## Example

      resolve_by_path([:customer, :customer_users, :user], lead)
  """
  def resolve_by_path(_path, nil), do: []

  def resolve_by_path(path, resource) when is_list(path) do
    result =
      Enum.reduce_while(path, resource, fn rel, acc ->
        case acc do
          %Ash.NotLoaded{} ->
            {:halt, nil}

          list when is_list(list) ->
            # Flatten if we encounter a list
            nested =
              Enum.flat_map(list, fn item ->
                case Map.get(item, rel) do
                  nil -> []
                  %Ash.NotLoaded{} -> []
                  value when is_list(value) -> value
                  value -> [value]
                end
              end)

            {:cont, nested}

          map when is_map(map) ->
            case Map.get(map, rel) do
              %Ash.NotLoaded{} -> {:halt, nil}
              nil -> {:halt, nil}
              value -> {:cont, value}
            end

          _ ->
            {:halt, nil}
        end
      end)

    case result do
      nil -> []
      list when is_list(list) -> list
      value -> [value]
    end
  end

  @doc """
  Combine multiple audiences (union, deduped by id).

  ## Example

      resolve_combined([:owner, :team], resource, context, MyApp.RecipientResolver)
  """
  def resolve_combined(audience_names, resource, context, resolver_module) do
    audience_names
    |> Enum.flat_map(fn name ->
      resolve(resolver_module, name, resource, context)
    end)
    |> Enum.uniq_by(& &1.id)
  end

  @doc """
  Call custom resolver function.

  ## Examples

      # Atom - calls resolver_module.resolve_owner(resource, context)
      resolve_custom(:resolve_owner, resource, context, resolver_module)

      # Tuple - calls Module.function(resource, context)
      resolve_custom({Module, :function}, resource, context, resolver_module)
  """
  def resolve_custom(func_name, resource, context, resolver_module) when is_atom(func_name) do
    if function_exported?(resolver_module, func_name, 2) do
      case apply(resolver_module, func_name, [resource, context]) do
        result when is_list(result) -> result
        nil -> []
        value -> [value]
      end
    else
      Logger.warning("""
      [AshDispatch.RecipientResolver] Custom resolver function not found: #{func_name}/2
      Module: #{inspect(resolver_module)}
      """)

      []
    end
  end

  def resolve_custom({module, func}, resource, context, _resolver_module) do
    case apply(module, func, [resource, context]) do
      result when is_list(result) -> result
      nil -> []
      value -> [value]
    end
  end

  def resolve_custom({module, func, extra_args}, resource, context, _resolver_module) do
    case apply(module, func, [resource, context | extra_args]) do
      result when is_list(result) -> result
      nil -> []
      value -> [value]
    end
  end
end
