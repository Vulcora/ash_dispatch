defmodule AshDispatch.PolicyChecks.HasPermission do
  @moduledoc """
  Policy check that delegates to a configured permission checker.

  This allows the consuming application to define how permissions are checked
  without ash_dispatch needing to know about the application's permission system.

  ## Configuration

  Set the permission checker module in your config:

      config :ash_dispatch,
        permission_checker: MyApp.Accounts.PolicyHelpers.HasPermission

  The permission checker module should implement the Ash.Policy.Check behaviour
  and accept a `permission` option.
  """

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(opts) do
    "has permission #{inspect(opts[:permission])}"
  end

  @impl true
  def match?(_actor, %{authorize?: false}, _opts), do: true

  def match?(nil, _context, _opts), do: false

  def match?(actor, context, opts) do
    permission_checker = Application.get_env(:ash_dispatch, :permission_checker)

    if permission_checker do
      # Delegate to the configured permission checker
      permission_checker.match?(actor, context, opts)
    else
      # No permission checker configured - deny by default
      false
    end
  end
end
