defmodule AshDispatch.Extensions.AddUserRelationship do
  @moduledoc """
  Spark DSL extension that adds a `user` belongs_to relationship to DeliveryReceipt.

  This allows consuming applications to add a proper relationship (instead of calculation)
  so that AshTypescript can load nested user fields.

  ## Usage

  Configure in the consuming app:

      config :ash_dispatch,
        user_resource: MyApp.Accounts.User

  When the consuming app compiles, the transformer will:
  1. Check if user_resource module exists
  2. If yes: Remove :user calculation and add :user relationship
  3. If no: Leave :user calculation as-is

  This avoids compile-time warnings when ash_dispatch compiles standalone,
  while providing a proper relationship when compiled with the consuming app.
  """

  use Spark.Dsl.Extension,
    transformers: [AshDispatch.Extensions.AddUserRelationship.Transformer]
end
