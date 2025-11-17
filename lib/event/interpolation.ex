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
  4. Nested access not supported (use prepare_template_assigns)
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

    # Find all {{variable}} patterns and replace them
    Regex.replace(~r/\{\{([a-zA-Z_][a-zA-Z0-9_]*)\}\}/, string, fn _, var_name ->
      var_atom = String.to_atom(var_name)

      # Try assigns first, then context.data
      case Map.get(assigns, var_atom) do
        nil -> get_from_context_data(context, var_atom)
        value -> to_string_safe(value)
      end
    end)
  end

  # Private helpers

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
    # Extract all {{variable}} patterns
    variables =
      Regex.scan(~r/\{\{([a-zA-Z_][a-zA-Z0-9_]*)\}\}/, string)
      |> Enum.map(fn [_, var] -> var end)

    # Check for invalid patterns
    invalid =
      Regex.scan(~r/\{\{([^}]*)\}\}/, string)
      |> Enum.map(fn [_, var] -> var end)
      |> Enum.reject(fn var -> var =~ ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/ end)

    case invalid do
      [] -> {:ok, variables}
      [first | _] -> {:error, "Invalid variable name: #{first}"}
    end
  end
end
