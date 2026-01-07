defmodule AshDispatch.Event.Interpolation do
  @moduledoc """
  Handles variable interpolation in DSL content strings.

  Supports {{variable}} syntax for interpolating values from:
  1. Context data (ctx.data.variable)
  2. Template assigns from prepare_template_assigns/2

  ## Examples

      # In DSL:
      content do
        subject "Order #\{\{order_number\}\} created"
        notification_message "Your order for \{\{total_items\}\} items is ready"
      end

      # In event module:
      def prepare_template_assigns(context, channel) do
        %{
          order_number: format_order_id(context.data.order),
          total_items: length(context.data.order.items)
        }
      end

  ## Interpolation Rules

  1. Variables are looked up in template assigns first
  2. Fallback to context.data with same key
  3. Missing variables render as empty string (no errors)
  4. Nested access is supported with dot notation: {{project.name}}
  """

  alias AshDispatch.{Channel, Context}

  @doc """
  Interpolates {{variable}} placeholders in a string.

  ## Examples

      iex> context = %Context{data: %{user: %{name: "John"}}}
      iex> Interpolation.interpolate("Hello {{user_name}}", context, channel, event_module)
      "Hello John"

      iex> Interpolation.interpolate("No variables here", context, channel, event_module)
      "No variables here"
  """
  @spec interpolate(String.t() | nil, Context.t(), Channel.t(), module()) :: String.t()
  def interpolate(nil, _context, _channel, _event_module), do: ""
  def interpolate("", _context, _channel, _event_module), do: ""

  def interpolate(string, context, channel, event_module) when is_binary(string) do
    # Get template assigns from event module
    assigns = event_module.prepare_template_assigns(context, channel)

    # Find all {{variable}} or {{variable.path}} patterns and replace them
    # Supports both simple {{name}} and nested {{user.name}} or {{project.name}}
    Regex.replace(~r/\{\{([a-zA-Z_][a-zA-Z0-9_.]*)\}\}/, string, fn _, var_path ->
      resolve_variable_path(var_path, assigns, context)
    end)
  end

  # Private helpers

  # Resolve a variable path like "project.name" or simple "name"
  defp resolve_variable_path(var_path, assigns, context) do
    path_parts = String.split(var_path, ".")

    case path_parts do
      [simple_key] ->
        # Simple variable like {{name}}
        var_atom = String.to_atom(simple_key)

        case Map.get(assigns, var_atom) do
          nil -> get_from_context_data(context, var_atom)
          value -> to_string_safe(value)
        end

      [first | rest] ->
        # Nested path like {{project.name}} or {{user.email}}
        first_atom = String.to_atom(first)
        rest_atoms = Enum.map(rest, &String.to_atom/1)

        # Try assigns first
        case Map.get(assigns, first_atom) do
          nil ->
            # Try context.data
            case Map.get(context.data, first_atom) do
              nil -> ""
              root_value -> get_nested_value(root_value, rest_atoms)
            end

          root_value ->
            get_nested_value(root_value, rest_atoms)
        end
    end
  end

  # Navigate nested struct/map path
  defp get_nested_value(value, []), do: to_string_safe(value)

  defp get_nested_value(value, [key | rest]) when is_map(value) do
    case Map.get(value, key) do
      nil -> ""
      nested -> get_nested_value(nested, rest)
    end
  end

  defp get_nested_value(_value, _path), do: ""

  defp get_from_context_data(%Context{data: data}, key) do
    case Map.get(data, key) do
      nil -> ""
      value -> to_string_safe(value)
    end
  end

  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value) when is_integer(value), do: Integer.to_string(value)
  defp to_string_safe(value) when is_float(value), do: Float.to_string(value)
  defp to_string_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp to_string_safe(_value), do: ""

  @doc """
  Validates interpolation string for valid variable names.

  Returns {:ok, variables} or {:error, reason}.

  ## Examples

      iex> Interpolation.validate("Order #\{\{order_number\}\}")
      {:ok, ["order_number"]}

      iex> Interpolation.validate("Invalid \{\{123invalid\}\}")
      {:error, "Invalid variable name: 123invalid"}
  """
  @spec validate(String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def validate(string) when is_binary(string) do
    # Extract all {{variable}} or {{variable.path}} patterns
    variables =
      Regex.scan(~r/\{\{([a-zA-Z_][a-zA-Z0-9_.]*)\}\}/, string)
      |> Enum.map(fn [_, var] -> var end)

    # Check for invalid patterns (must be valid identifier or dot-separated identifiers)
    invalid =
      Regex.scan(~r/\{\{([^}]*)\}\}/, string)
      |> Enum.map(fn [_, var] -> var end)
      |> Enum.reject(fn var -> var =~ ~r/^[a-zA-Z_][a-zA-Z0-9_.]*$/ end)

    case invalid do
      [] -> {:ok, variables}
      [first | _] -> {:error, "Invalid variable name: #{first}"}
    end
  end
end
