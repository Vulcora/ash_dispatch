if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshDispatch.Gen.RecipientResolver do
    @example "mix ash_dispatch.gen.recipient_resolver MyApp.RecipientResolver"
    @moduledoc """
    Generates an AshDispatch.RecipientResolver module for declarative audience resolution.

    ## Example

    ```bash
    #{@example}
    ```

    ## Options

    * `--user-resource` - The user resource module (defaults to `MyApp.Accounts.User`)

    ## Generated Code

    The generator creates a recipient resolver with:
    - A `to_recipient/1` callback for formatting user structs as recipient maps
    - Example audiences using different resolution strategies
    - Comments explaining each strategy

    ## Usage

    After generation, configure ash_dispatch to use your resolver:

    ```elixir
    config :ash_dispatch,
      recipient_resolver: MyApp.RecipientResolver
    ```

    Then reference audiences in your dispatch DSL:

    ```elixir
    dispatch do
      event :order_created do
        channel :in_app, audience: :owner
        channel :email, audience: :admins
      end
    end
    ```
    """

    @shortdoc "Generates an AshDispatch.RecipientResolver module"
    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        positional: [:resolver],
        schema: [
          user_resource: :string
        ],
        example: @example
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      resolver = Igniter.Project.Module.parse(igniter.args.positional.resolver)
      app_name = Igniter.Project.Application.app_name(igniter)

      user_resource =
        case igniter.args.options[:user_resource] do
          nil ->
            # Default to MyApp.Accounts.User
            app_module = Macro.camelize(to_string(app_name))
            Module.concat([app_module, Accounts, User])

          resource ->
            Module.concat([resource])
        end

      {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, resolver)

      if "--ignore-if-exists" in igniter.args.argv_flags && exists? do
        igniter
      else
        igniter
        |> Igniter.Project.Module.create_module(resolver, """
        @moduledoc \"\"\"
        Recipient resolver for notification audiences.

        Define how to resolve recipients for each audience type using
        the AshDispatch.RecipientResolver DSL.

        ## Audience Strategies

        | Strategy | Example | Description |
        |----------|---------|-------------|
        | `from_context` | `from_context: :user` | Extract from context.data |
        | `query` | `query: [role: :admin]` | Query user_resource with Ash filter |
        | `path` | `path: [:team, :users]` | Follow relationship path on resource |
        | `combine` | `combine: [:owner, :team]` | Union of other audiences |
        | `resolve` | `resolve: :resolve_owner` | Custom resolver function |

        ## Usage

        Reference audiences in your dispatch DSL:

            dispatch do
              event :order_created do
                channel :in_app, audience: :owner
                channel :email, audience: :team
              end
            end
        \"\"\"

        use AshDispatch.RecipientResolver,
          user_resource: #{inspect(user_resource)}

        audiences do
          # Context-based - extract user from event context
          audience :user, from_context: :user

          # Fallback chain - tries :user first, then :assignee
          audience :assignee, from_context: [:user, :assignee]

          # Query-based - find users matching filter
          # audience :admins, query: [role: :admin, is_active: true]

          # Relationship path - follow relationships on the resource
          # audience :team, path: [:team_members, :user]

          # Composite - union of other audiences (deduped by id)
          # audience :stakeholders, combine: [:owner, :team]

          # Custom resolver - for complex business logic
          # audience :owner, resolve: :resolve_owner

          # Custom resolver returning raw maps (not user structs)
          # audience :lead_contact, resolve: :resolve_lead_contact, raw: true
        end

        @impl true
        def to_recipient(%#{inspect(user_resource)}{} = user) do
          %{
            id: user.id,
            email: to_string(user.email),
            display_name: extract_display_name(user)
          }
        end

        defp extract_display_name(user) do
          cond do
            Map.has_key?(user, :full_name) && user.full_name ->
              to_string(user.full_name)

            Map.has_key?(user, :first_name) && user.first_name ->
              to_string(user.first_name)

            true ->
              to_string(user.email)
          end
        end

        # Example custom resolver:
        #
        # def resolve_owner(resource, context) do
        #   case Map.get(context.data, :owner) do
        #     nil -> []
        #     owner -> [owner]
        #   end
        # end
        """)
        |> Igniter.Project.Config.configure_new(
          "config.exs",
          :ash_dispatch,
          [:recipient_resolver],
          resolver
        )
      end
    end
  end
else
  defmodule Mix.Tasks.AshDispatch.Gen.RecipientResolver do
    @example "mix ash_dispatch.gen.recipient_resolver MyApp.RecipientResolver"
    @moduledoc """
    Generates an AshDispatch.RecipientResolver module for declarative audience resolution.

    ## Example

    ```bash
    #{@example}
    ```

    This task requires Igniter. Please install igniter and try again.
    For more information, see: https://hexdocs.pm/igniter
    """

    @shortdoc "Generates an AshDispatch.RecipientResolver module"

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_dispatch.gen.recipient_resolver' requires igniter.

      Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter
      """)

      exit({:shutdown, 1})
    end
  end
end
