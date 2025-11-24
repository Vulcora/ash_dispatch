defmodule AshDispatch.RecipientResolver.Default do
  @moduledoc """
  Default recipient resolver that raises errors.

  This is used when no custom resolver is configured. Following Elixir's
  "let it crash" philosophy, it raises explicit errors for admin/team/system
  audiences to force developers to implement proper recipient resolution.

  ## Usage

  This module is used automatically if you don't configure a resolver.
  To fix these errors, configure your own resolver:

      # config/config.exs
      config :ash_dispatch,
        recipient_resolver: MyApp.Recipients.Resolver

  See `AshDispatch.RecipientResolver` for implementation guide.
  """

  @behaviour AshDispatch.RecipientResolver

  @impl true
  def resolve_admins(_context) do
    raise """
    Admin recipient resolution not implemented!

    To enable admin notifications, configure a recipient resolver:

        # config/config.exs
        config :ash_dispatch,
          recipient_resolver: MyApp.Recipients.Resolver

    See AshDispatch.RecipientResolver documentation for details.
    """
  end

  @impl true
  def resolve_team(team_name, _context) do
    raise """
    Team recipient resolution not implemented!

    Attempted to resolve team: #{inspect(team_name)}

    To enable team notifications, configure a recipient resolver:

        # config/config.exs
        config :ash_dispatch,
          recipient_resolver: MyApp.Recipients.Resolver

    See AshDispatch.RecipientResolver documentation for details.
    """
  end

  @impl true
  def resolve_system(_context) do
    raise """
    System recipient resolution not implemented!

    To enable system notifications, configure a recipient resolver:

        # config/config.exs
        config :ash_dispatch,
          recipient_resolver: MyApp.Recipients.Resolver

    See AshDispatch.RecipientResolver documentation for details.
    """
  end
end
