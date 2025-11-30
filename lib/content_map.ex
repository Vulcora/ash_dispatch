defmodule AshDispatch.ContentMap do
  @moduledoc """
  Helper module for accessing content maps with mixed atom/string keys.

  Content maps may have atom keys when created in-memory, but string keys when
  loaded from the database (PostgreSQL JSONB columns return string keys).
  This module provides safe access that handles both cases.

  ## Why This Exists

  When you store a map like `%{title: "Hello"}` in a JSONB column,
  PostgreSQL returns it as `%{"title" => "Hello"}`. This module
  eliminates the `content[:title] || content["title"]` pattern
  scattered throughout transport code.

  ## Usage

      import AshDispatch.ContentMap

      # Get a value (checks atom key first, then string)
      title = get_content(content, :title)

      # Get with default
      type = get_content(content, :notification_type, :info)

  ## Key Resolution Order

  1. Atom key (e.g., `:title`)
  2. String key (e.g., `"title"`)
  3. Default value (if provided)
  """

  @doc """
  Gets a value from a content map, handling both atom and string keys.

  Checks atom key first, then string key. Returns nil if not found.

  ## Examples

      iex> get_content(%{title: "Hello"}, :title)
      "Hello"

      iex> get_content(%{"title" => "Hello"}, :title)
      "Hello"

      iex> get_content(%{}, :title)
      nil
  """
  @spec get_content(map(), atom()) :: any()
  def get_content(content, key) when is_map(content) and is_atom(key) do
    content[key] || content[Atom.to_string(key)]
  end

  def get_content(nil, _key), do: nil
  def get_content(_content, _key), do: nil

  @doc """
  Gets a value from a content map with a default if not found.

  ## Examples

      iex> get_content(%{}, :notification_type, :info)
      :info

      iex> get_content(%{notification_type: :success}, :notification_type, :info)
      :success
  """
  @spec get_content(map(), atom(), any()) :: any()
  def get_content(content, key, default) when is_map(content) and is_atom(key) do
    get_content(content, key) || default
  end

  def get_content(nil, _key, default), do: default
  def get_content(_content, _key, default), do: default
end
