defmodule AshDispatch.RecipientResolver do
  @moduledoc """
  Behaviour and DSL for declarative recipient resolution.

  This module provides a declarative way to define how notification recipients
  are resolved for each audience type, following Ash Framework patterns.

  ## Usage

  Create a resolver module in your application:

      defmodule MyApp.RecipientResolver do
        use AshDispatch.RecipientResolver,
          user_resource: MyApp.Accounts.User

        audiences do
          # Context-based - extract from event context
          audience :user, from_context: :user
          audience :assignee, from_context: [:user, :assignee]

          # Query-based - query user resource with filter
          audience :admins, query: [role: :admin, is_active: true]

          # Relationship path - follow relationships on resource
          audience :team, path: [:team_members, :user]

          # Composite - union of other audiences
          audience :stakeholders, combine: [:owner, :team]

          # Custom resolver - for complex business logic
          audience :owner, resolve: :resolve_owner

          # Non-user recipient - extract email/name from resource fields
          audience :lead_contact, from_resource: [email: :contact_email, name: :contact_name]
        end

        @impl true
        def to_recipient(%MyApp.Accounts.User{} = user) do
          %{
            id: user.id,
            email: to_string(user.email),
            display_name: user.full_name || to_string(user.email)
          }
        end

        def resolve_owner(resource, context) do
          # Your custom logic
        end
      end

  Then configure ash_dispatch to use it:

      config :ash_dispatch,
        recipient_resolver: MyApp.RecipientResolver

  ## Audience Resolution Strategies

  | Strategy | DSL | Description |
  |----------|-----|-------------|
  | `from_context` | `audience :user, from_context: :user` | Extract from context.data |
  | `from_context` (fallback) | `audience :assignee, from_context: [:user, :assignee]` | Try each key until non-nil |
  | `from_context` + `extract` | `audience :participants, from_context: [:meeting, :participants], extract: :user` | Get collection, extract field |
  | `from_resource` | `audience :lead_contact, from_resource: [email: :contact_email, name: :contact_name]` | Extract email/name from resource fields |
  | `query` | `audience :admins, query: [role: :admin]` | Query user_resource with Ash filter |
  | `path` | `audience :team, path: [:team_members, :user]` | Follow relationship path on resource |
  | `combine` | `audience :stakeholders, combine: [:owner, :team]` | Union of other audiences (deduped) |
  | `resolve` | `audience :owner, resolve: :resolve_owner` | Custom function |
  | `resolve` + `raw` | `audience :lead_contact, resolve: :fn, raw: true` | Custom function, skip to_recipient |
  """

  @doc """
  Convert a user struct to a recipient map.

  The returned map must have at minimum:
  - `:id` - unique identifier for deduplication
  - `:email` - email address for email transport

  Optional fields:
  - `:display_name` - name shown in templates
  - `:first_name` - first name for personalization
  """
  @callback to_recipient(user :: struct()) :: %{
              required(:id) => term(),
              required(:email) => String.t(),
              optional(:display_name) => String.t(),
              optional(:first_name) => String.t()
            }

  @doc """
  Resolve recipients for an audience.

  This callback is optional - if not implemented, the default resolution
  logic will be used based on the `audiences` DSL configuration.
  """
  @callback resolve(audience :: atom(), resource :: struct() | nil, context :: map()) :: [map()]

  @optional_callbacks [resolve: 3]

  defmacro __using__(opts) do
    quote do
      @behaviour AshDispatch.RecipientResolver

      import AshDispatch.RecipientResolver.Dsl, only: [audiences: 1, audience: 2]

      Module.register_attribute(__MODULE__, :audiences, accumulate: true)

      @user_resource unquote(opts[:user_resource]) ||
                       raise(ArgumentError, "user_resource is required")

      @before_compile AshDispatch.RecipientResolver

      @doc false
      def __user_resource__, do: @user_resource
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      @doc false
      def __audiences__ do
        @audiences |> Enum.reverse()
      end

      # Default to_recipient implementation if not defined
      unless Module.defines?(__MODULE__, {:to_recipient, 1}) do
        @impl true
        def to_recipient(user) when is_struct(user) do
          %{
            id: user.id,
            email: extract_email(user),
            display_name: extract_display_name(user)
          }
        end

        defp extract_email(user) do
          case Map.get(user, :email) do
            %{string: str} -> str
            str when is_binary(str) -> str
            other -> to_string(other)
          end
        end

        defp extract_display_name(user) do
          cond do
            Map.has_key?(user, :full_name) && user.full_name ->
              to_string(user.full_name)

            Map.has_key?(user, :first_name) && user.first_name ->
              to_string(user.first_name)

            true ->
              extract_email(user)
          end
        end
      end

      # Default resolve implementation using DSL configuration
      unless Module.defines?(__MODULE__, {:resolve, 3}) do
        @impl true
        def resolve(audience, resource, context) do
          AshDispatch.RecipientResolver.Resolver.resolve(
            __MODULE__,
            audience,
            resource,
            context
          )
        end
      end
    end
  end
end
