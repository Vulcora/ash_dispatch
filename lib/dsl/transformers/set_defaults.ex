defmodule AshDispatch.Dsl.Transformers.SetDefaults do
  @moduledoc """
  Transformer that sets default values for event configuration.

  Ensures all events have sensible defaults even if not specified in DSL.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def transform(dsl_state) do
    dsl_state =
      dsl_state
      |> ensure_user_configurable()
      |> ensure_notification_type()
      |> ensure_action_required()

    {:ok, dsl_state}
  end

  # Ensure user_configurable? has a default
  defp ensure_user_configurable(dsl_state) do
    case Transformer.get_option(dsl_state, [:dispatch], :user_configurable?) do
      nil ->
        Transformer.set_option(dsl_state, [:dispatch], :user_configurable?, true)

      _ ->
        dsl_state
    end
  end

  # Ensure notification_type has a default
  defp ensure_notification_type(dsl_state) do
    case Transformer.get_option(dsl_state, [:dispatch, :metadata], :notification_type) do
      nil ->
        Transformer.set_option(dsl_state, [:dispatch, :metadata], :notification_type, :info)

      _ ->
        dsl_state
    end
  end

  # Ensure action_required? has a default
  defp ensure_action_required(dsl_state) do
    case Transformer.get_option(dsl_state, [:dispatch, :metadata], :action_required?) do
      nil ->
        Transformer.set_option(dsl_state, [:dispatch, :metadata], :action_required?, false)

      _ ->
        dsl_state
    end
  end
end
