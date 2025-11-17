defmodule AshDispatch.RecipientResolver.Default do
  @moduledoc """
  Default recipient resolver that logs warnings.

  This is used when no custom resolver is configured. It returns empty lists
  for admin/team/system audiences and logs warnings to help developers
  realize they need to configure a resolver.

  ## Usage

  This module is used automatically if you don't configure a resolver.
  To stop seeing warnings, configure your own resolver:

      # config/config.exs
      config :ash_dispatch,
        recipient_resolver: MyApp.Recipients.Resolver

  See `AshDispatch.RecipientResolver` for implementation guide.
  """

  @behaviour AshDispatch.RecipientResolver

  require Logger

  @impl true
  def resolve_admins(_context) do
    Logger.warning("""
    Admin recipient resolution not implemented!

    To enable admin notifications, configure a recipient resolver:

        # config/config.exs
        config :ash_dispatch,
          recipient_resolver: MyApp.Recipients.Resolver

    See AshDispatch.RecipientResolver documentation for details.
    """)

    []
  end

  @impl true
  def resolve_team(team_name, _context) do
    Logger.warning("""
    Team recipient resolution not implemented!

    Attempted to resolve team: #{inspect(team_name)}

    To enable team notifications, configure a recipient resolver:

        # config/config.exs
        config :ash_dispatch,
          recipient_resolver: MyApp.Recipients.Resolver

    See AshDispatch.RecipientResolver documentation for details.
    """)

    []
  end

  @impl true
  def resolve_system(_context) do
    Logger.warning("""
    System recipient resolution not implemented!

    To enable system notifications, configure a recipient resolver:

        # config/config.exs
        config :ash_dispatch,
          recipient_resolver: MyApp.Recipients.Resolver

    See AshDispatch.RecipientResolver documentation for details.
    """)

    []
  end
end
