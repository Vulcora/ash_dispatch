defmodule AshDispatch.VariableInterpolator do
  @moduledoc """
  Interpolates variables in template strings.

  Replaces `{{variable}}` placeholders with actual values from event data.

  ## Examples

  Basic interpolation:

      iex> interpolate("Order #\{{id}}", %{order: %{id: 123}}, :order)
      "Order #123"

  Nested attributes (preloaded relationships):

      iex> interpolate("Hello \{{user.name}}", %{order: %{user: %{name: "Alice"}}}, :order)
      "Hello Alice"

  Flattened keys (user.name becomes user_name):

      iex> interpolate("Hello \{{user_name}}", %{order: %{user: %{name: "Alice"}}}, :order)
      "Hello Alice"

  Missing values become empty string:

      iex> interpolate("Value: \{{missing}}", %{order: %{}}, :order)
      "Value: "

  ## Variable Syntax

  Variables use double curly braces: `\{{variable_name}}`

  **Direct attributes:**
  - `{{id}}` → resource.id
  - `{{status}}` → resource.status
  - `{{total}}` → resource.total

  **Nested attributes (dot notation):**
  - `{{user.name}}` → resource.user.name
  - `{{user.email}}` → resource.user.email
  - `{{organization.name}}` → resource.organization.name

  **Flattened keys (underscore notation):**
  - `{{user_name}}` → resource.user.name
  - `{{user_email}}` → resource.user.email
  - `{{organization_name}}` → resource.organization.name

  ## Resource Key

  The `resource_key` parameter specifies which key in the data map contains
  the main resource record:

      data = %{order: %Order{id: 123}, user: %User{name: "Alice"}}

      interpolate("Order {{id}}", data, :order)
      # Uses data.order for variable lookup

  ## Preloading

  For nested attributes to work, relationships must be preloaded:

      dispatch do
        event :created,
          load: [:user, :organization],  # Preload relationships
          content: [
            notification_message: "{{user_name}} created order in {{organization_name}}"
          ]
      end

  ## Type Conversion

  Values are converted to strings:
  - Atoms: `:active` → "active"
  - Numbers: `123` → "123"
  - Booleans: `true` → "true"
  - DateTime: `~U[2025-01-01 10:00:00Z]` → "2025-01-01 10:00:00Z"
  - Nil: `nil` → "" (empty string)

  ## Safety

  - Missing variables become empty strings (no errors)
  - Nil values become empty strings
  - Handles missing relationships gracefully
  - Does not execute code (just string replacement)
  """

  @doc """
  Interpolates variables in a template string.

  ## Parameters

  - `template` - String template with `{{variable}}` placeholders
  - `data` - Map containing event data (resource records)
  - `resource_key` - Atom key for the main resource in data map

  ## Returns

  String with variables replaced by actual values

  ## Examples

      iex> interpolate("Order #\{{id}}", %{order: %{id: 123}}, :order)
      "Order #123"

      iex> interpolate("\{{user.name}}", %{ticket: %{user: %{name: "Alice"}}}, :ticket)
      "Alice"

      iex> interpolate("\{{missing}}", %{order: %{}}, :order)
      ""
  """
  @spec interpolate(String.t(), map(), atom()) :: String.t()
  def interpolate(template, data, resource_key) when is_binary(template) do
    interpolate_against(template, data, resource_key)
  end

  def interpolate(nil, _data, _resource_key), do: ""
  def interpolate(template, _data, _resource_key) when not is_binary(template), do: ""

  defp interpolate_against(template, data, resource_key) do
    # Get the main resource record
    resource = Map.get(data, resource_key) || Map.get(data, to_string(resource_key))

    # Find all variables in template
    Regex.replace(~r/\{\{([^}]+)\}\}/, template, fn _, var_name ->
      var_name = String.trim(var_name)

      # Look in three places, in order:
      # 1. The main resource (most common — `{{id}}`, `{{user.name}}`).
      # 2. Top-level keys in `data` (so `prepare_template_assigns/2`-
      #    returned values land in `{{my_computed_var}}` without forcing
      #    callers to nest them under the resource).
      # 3. Other resources passed via `data_map` (e.g. `{{order.user.name}}`
      #    when both `:order` and `:user` are present at top level).
      resolved =
        case resolve_variable(var_name, resource) do
          nil ->
            resolve_top_level(var_name, data)

          "" ->
            # `resolve_top_level/2` only kicks in if the resource didn't
            # produce a meaningful value. Empty string from the resource
            # is treated as "not found" so a computed assign with the same
            # name can still surface.
            resolve_top_level(var_name, data) || ""

          val ->
            val
        end

      to_string_safe(resolved)
    end)
  end

  # Resolve `{{my_var}}` (or `{{a.b}}`) against the top-level `data` map.
  # Used as a fallback when the main resource doesn't carry the variable
  # — typically values injected by `prepare_template_assigns/2`.
  defp resolve_top_level(var_name, data) when is_map(data) do
    cond do
      String.contains?(var_name, ".") ->
        resolve_nested_path(String.split(var_name, "."), data)

      true ->
        try do
          key = String.to_existing_atom(var_name)
          Map.get(data, key) || Map.get(data, var_name)
        rescue
          ArgumentError -> Map.get(data, var_name)
        end
    end
  end

  # Private functions

  # Resolve a variable from the resource
  defp resolve_variable(var_name, resource) when is_map(resource) do
    cond do
      # Try dot notation first: user.name
      String.contains?(var_name, ".") ->
        resolve_nested_path(String.split(var_name, "."), resource)

      # Try underscore as flattened dot notation: user_name → user.name
      String.contains?(var_name, "_") ->
        parts = String.split(var_name, "_", parts: 2)

        case parts do
          [key, rest] ->
            # Try as nested first, but catch atom errors
            nested_value =
              try do
                key_atom = String.to_existing_atom(key)
                Map.get(resource, key_atom)
              rescue
                ArgumentError -> nil
              end

            case nested_value do
              nil ->
                # Fall back to direct attribute
                try do
                  Map.get(resource, String.to_existing_atom(var_name))
                rescue
                  ArgumentError -> nil
                end

              nested when is_map(nested) ->
                # Recursively resolve rest
                resolve_variable(rest, nested)

              _ ->
                # Not a map, try direct attribute
                try do
                  Map.get(resource, String.to_existing_atom(var_name))
                rescue
                  ArgumentError -> nil
                end
            end

          _ ->
            nil
        end

      # Direct attribute: id, status, etc.
      true ->
        try do
          Map.get(resource, String.to_existing_atom(var_name))
        rescue
          ArgumentError -> nil
        end
    end
  end

  defp resolve_variable(_var_name, _resource), do: nil

  # Resolve nested path like ["user", "name"]
  defp resolve_nested_path([], value), do: value

  defp resolve_nested_path([key | rest], resource) when is_map(resource) do
    case Map.get(resource, String.to_existing_atom(key)) do
      nil -> nil
      value -> resolve_nested_path(rest, value)
    end
  rescue
    ArgumentError -> nil
  end

  defp resolve_nested_path(_path, _resource), do: nil

  # Convert value to string safely
  defp to_string_safe(nil), do: ""
  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp to_string_safe(value) when is_integer(value), do: Integer.to_string(value)
  defp to_string_safe(value) when is_float(value), do: Float.to_string(value)

  defp to_string_safe(%DateTime{} = dt) do
    DateTime.to_string(dt)
  end

  defp to_string_safe(%Date{} = date) do
    Date.to_string(date)
  end

  defp to_string_safe(%Time{} = time) do
    Time.to_string(time)
  end

  defp to_string_safe(%_{} = struct) do
    # For other structs, try to convert to string
    to_string(struct)
  rescue
    _ -> ""
  end

  defp to_string_safe(value) when is_map(value) do
    # Don't convert maps to strings (would be useless)
    ""
  end

  defp to_string_safe(value) when is_list(value) do
    # Don't convert lists to strings
    ""
  end

  defp to_string_safe(_value), do: ""
end
