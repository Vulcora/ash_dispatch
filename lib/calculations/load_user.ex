defmodule AshDispatch.Calculations.LoadUser do
  @moduledoc """
  Calculation for loading user records from the configured user resource.

  This provides a clean way to load users without compile-time dependencies.
  The consuming application configures which user resource to use:

      config :ash_dispatch,
        user_resource: MyApp.Accounts.User,
        user_domain: MyApp.Accounts

  ## Usage

  In queries:

      DeliveryReceipt
      |> Ash.Query.load(:user)
      |> Ash.read!()

  The calculation will batch-load all users efficiently.
  """
  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context) do
    # Declare that we need user_id to perform this calculation
    [:user_id]
  end

  @impl true
  def calculate(records, _opts, context) do
    # Get user resource configuration
    user_resource = Application.get_env(:ash_dispatch, :user_resource)
    user_domain = Application.get_env(:ash_dispatch, :user_domain)

    if is_nil(user_resource) or is_nil(user_domain) do
      # No user resource configured - return nil for all records
      Enum.map(records, fn _ -> nil end)
    else
      # Get all user IDs that need to be loaded
      user_ids =
        records
        |> Enum.map(& &1.user_id)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      if Enum.empty?(user_ids) do
        # No user IDs to load
        Enum.map(records, fn _ -> nil end)
      else
        # Batch load all users
        require Ash.Query

        users =
          user_resource
          |> Ash.Query.filter(id in ^user_ids)
          |> Ash.read!(
            domain: user_domain,
            authorize?: Map.get(context, :authorize?, false),
            actor: Map.get(context, :actor)
          )
          |> Enum.map(fn user -> {user.id, user} end)
          |> Map.new()

        # Map users back to records
        Enum.map(records, fn record ->
          if record.user_id do
            Map.get(users, record.user_id)
          else
            nil
          end
        end)
      end
    end
  end
end
