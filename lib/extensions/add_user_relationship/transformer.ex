defmodule AshDispatch.Extensions.AddUserRelationship.Transformer do
  @moduledoc """
  Transformer that conditionally adds a `user` belongs_to relationship to the resource.

  This replaces the `:user` calculation with a proper relationship so AshTypescript
  can load nested fields.

  The transformer only creates the relationship if the configured user_resource module
  exists at compile time. This avoids warnings when ash_dispatch compiles standalone.
  """

  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  def transform(dsl) do
    # Get user_resource from config
    user_resource = Application.get_env(:ash_dispatch, :user_resource)

    if user_resource do
      # Try to compile the user_resource module
      # This will trigger compilation if we're in the consuming app
      # and will raise if the module truly doesn't exist
      case Code.ensure_compiled(user_resource) do
        {:module, _} ->
          # Module exists or was just compiled
          add_user_relationship(dsl, user_resource)

        {:error, _} ->
          # Module doesn't exist (we're in standalone ash_dispatch compilation)
          # Leave calculation as-is
          {:ok, dsl}
      end
    else
      # No user_resource configured
      {:ok, dsl}
    end
  end

  defp add_user_relationship(dsl, user_resource) do
    # Remove the :user calculation if it exists
    calculations = Transformer.get_entities(dsl, [:calculations])

    dsl =
      if Enum.any?(calculations, &(&1.name == :user)) do
        Transformer.remove_entity(dsl, [:calculations], fn calc -> calc.name == :user end)
      else
        dsl
      end

    # Add the :user relationship
    relationship = %Ash.Resource.Relationships.BelongsTo{
      name: :user,
      destination: user_resource,
      source_attribute: :user_id,
      destination_attribute: :id,
      allow_nil?: true,
      public?: true,
      define_attribute?: false
    }

    {:ok, Transformer.add_entity(dsl, [:relationships], relationship)}
  end
end
