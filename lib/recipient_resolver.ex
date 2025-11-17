defmodule AshDispatch.RecipientResolver do
  @moduledoc """
  Behaviour for resolving recipients from audience types.

  AshDispatch doesn't know about your User resource, so you provide
  a resolver module that implements this behaviour.

  ## Configuration

  Configure your resolver module:

      # config/config.exs
      config :ash_dispatch,
        recipient_resolver: MyApp.Recipients.Resolver

  ## Implementation

      defmodule MyApp.Recipients.Resolver do
        @behaviour AshDispatch.RecipientResolver

        alias MyApp.Accounts.User

        @impl true
        def resolve_admins(_context) do
          # Query your admin users
          User
          |> Ash.Query.filter(admin == true)
          |> Ash.read!()
        end

        @impl true
        def resolve_team(team_name, _context) do
          # Query team members
          case team_name do
            :support ->
              User
              |> Ash.Query.filter(role == :support)
              |> Ash.read!()

            :engineering ->
              User
              |> Ash.Query.filter(department == "Engineering")
              |> Ash.read!()

            _ ->
              []
          end
        end

        @impl true
        def resolve_system(_context) do
          # Return system notification recipients (e.g., ops team)
          [
            %{email: "ops@myapp.com", name: "Operations Team"}
          ]
        end
      end

  ## Built-in Resolvers

  If you don't configure a resolver, AshDispatch uses a default that:
  - Returns empty list for admins/teams/system (with warning logs)
  - This ensures your app doesn't break, but you'll see warnings

  ## Context

  The `context` parameter is an `%AshDispatch.Context{}` struct containing:
  - `event_id` - Event identifier
  - `data` - Event data (resource record, etc.)
  - `user` - Current user (if available)
  - `metadata` - Additional context

  Use this to implement dynamic recipient resolution:

      def resolve_admins(context) do
        # Only notify admins in the same organization
        if org_id = context.data.order.organization_id do
          User
          |> Ash.Query.filter(admin == true and organization_id == ^org_id)
          |> Ash.read!()
        else
          []
        end
      end
  """

  alias AshDispatch.Context

  @doc """
  Resolve admin recipients.

  Should return a list of user records or maps with `:email` field.

  ## Examples

      def resolve_admins(_context) do
        User
        |> Ash.Query.filter(admin == true)
        |> Ash.read!()
      end

      def resolve_admins(context) do
        # Org-specific admins
        User
        |> Ash.Query.filter(
          admin == true and
          organization_id == ^context.data.order.organization_id
        )
        |> Ash.read!()
      end
  """
  @callback resolve_admins(context :: Context.t()) :: list()

  @doc """
  Resolve team recipients by team name.

  Team name is an atom (e.g., `:support`, `:engineering`, `:sales`).

  Should return a list of user records or maps with `:email` field.

  ## Examples

      def resolve_team(:support, _context) do
        User
        |> Ash.Query.filter(role == :support)
        |> Ash.read!()
      end

      def resolve_team(team_name, _context) do
        Team
        |> Ash.get!(team_name)
        |> Ash.load!(:members)
        |> Map.get(:members)
      end
  """
  @callback resolve_team(team_name :: atom(), context :: Context.t()) :: list()

  @doc """
  Resolve system recipients.

  Used for internal notifications (monitoring, ops, etc.).

  Should return a list of user records or maps with `:email` field.

  ## Examples

      def resolve_system(_context) do
        [
          %{email: "ops@myapp.com", name: "Operations"},
          %{email: "monitoring@myapp.com", name: "Monitoring"}
        ]
      end

      def resolve_system(_context) do
        User
        |> Ash.Query.filter(role == :ops)
        |> Ash.read!()
      end
  """
  @callback resolve_system(context :: Context.t()) :: list()

  @doc """
  Resolve recipients for the given audience type.

  This is the main entry point used by transports. It delegates to
  the configured resolver module, or uses the default resolver if none
  is configured.

  ## Parameters

  - `audience` - Audience type (`:user`, `:admin`, `:team`, `:system`)
  - `context` - Event context
  - `opts` - Additional options (e.g., `team: :support`)

  ## Returns

  List of recipients (user records or maps with `:email` field)

  ## Examples

      # User audience (from context)
      RecipientResolver.resolve(:user, context, [])
      # => [%User{email: "user@example.com"}]

      # Admin audience (via configured resolver)
      RecipientResolver.resolve(:admin, context, [])
      # => [%User{email: "admin1@example.com"}, %User{email: "admin2@example.com"}]

      # Team audience
      RecipientResolver.resolve(:team, context, team: :support)
      # => [%User{email: "support1@example.com"}, ...]
  """
  @spec resolve(atom(), Context.t(), keyword()) :: list()
  def resolve(audience, context, opts \\ [])

  def resolve(:user, context, _opts) do
    case context.user do
      nil ->
        []

      user ->
        [user]
    end
  end

  def resolve(:admin, context, _opts) do
    resolver = get_resolver()
    resolver.resolve_admins(context)
  end

  def resolve(:team, context, opts) do
    team_name = Keyword.get(opts, :team)

    if team_name do
      resolver = get_resolver()
      resolver.resolve_team(team_name, context)
    else
      []
    end
  end

  def resolve(:system, context, _opts) do
    resolver = get_resolver()
    resolver.resolve_system(context)
  end

  def resolve(audience, _context, _opts) do
    require Logger
    Logger.warning("Unknown audience type: #{inspect(audience)}")
    []
  end

  # Private helpers

  defp get_resolver do
    Application.get_env(:ash_dispatch, :recipient_resolver, __MODULE__.Default)
  end
end
