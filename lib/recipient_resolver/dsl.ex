defmodule AshDispatch.RecipientResolver.Dsl do
  @moduledoc """
  DSL macros for defining audiences in a RecipientResolver.

  ## Example

      audiences do
        audience :user, from_context: :user
        audience :admins, query: [role: :admin]
        audience :owner, resolve: :resolve_owner
      end
  """

  @doc """
  Define audiences block.

  All audience definitions must be inside this block.
  """
  defmacro audiences(do: block) do
    quote do
      unquote(block)
    end
  end

  @doc """
  Define an audience with its resolution strategy.

  ## Options

  * `:from_context` - Extract from context.data. Can be:
    * An atom: `from_context: :user` extracts `context.data.user`
    * A list of atoms: `from_context: [:user, :assignee]` tries each key until non-nil

  * `:extract` - When using `from_context` with a collection, extract this field from each item.
    Example: `from_context: [:meeting, :participants], extract: :user`

  * `:query` - Ash filter to query user_resource.
    Example: `query: [role: :admin, is_active: true]`

  * `:path` - Relationship path to follow from the resource.
    Example: `path: [:customer, :customer_users, :user]`

  * `:combine` - Union of other audiences (deduped by id).
    Example: `combine: [:owner, :team]`

  * `:resolve` - Custom resolver function. Can be:
    * An atom: function name in this module, called as `function_name(resource, context)`
    * A tuple: `{Module, :function}` or `{Module, :function, extra_args}`

  * `:raw` - When `true`, skip `to_recipient/1` conversion. Use for audiences
    that return pre-formatted recipient maps instead of user structs.
    Default: `false`

  ## Examples

      # Extract from context
      audience :user, from_context: :user

      # Try multiple context keys
      audience :assignee, from_context: [:user, :assignee]

      # Extract field from collection
      audience :participants, from_context: [:meeting, :participants], extract: :user

      # Query users
      audience :admins, query: [role: :admin, is_active: true]

      # Follow relationship path
      audience :customer_users, path: [:customer, :users]

      # Combine audiences
      audience :stakeholders, combine: [:owner, :team]

      # Custom resolver
      audience :owner, resolve: :resolve_owner

      # Custom resolver returning raw maps
      audience :lead_contact, resolve: :resolve_lead_contact, raw: true
  """
  defmacro audience(name, opts) do
    quote do
      @audiences %{
        name: unquote(name),
        from_context: unquote(opts[:from_context]),
        extract: unquote(opts[:extract]),
        query: unquote(opts[:query]),
        path: unquote(opts[:path]),
        combine: unquote(opts[:combine]),
        resolve: unquote(opts[:resolve]),
        raw: unquote(opts[:raw]) || false
      }
    end
  end
end
