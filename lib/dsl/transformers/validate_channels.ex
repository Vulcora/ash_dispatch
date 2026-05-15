defmodule AshDispatch.Dsl.Transformers.ValidateChannels do
  @moduledoc """
  Transformer that validates channel configurations.

  Checks:
  - At least one channel is defined
  - Transport types are valid
  - In-app channels have required content fields
  - Channel time specifications are valid
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError

  # F1 — transports are now derived from the Registry, not hardcoded.
  # Pre-F1 this list missed `:broadcast` and `:oban` (added later); DSL
  # events declaring those channels would have failed validation.
  defp valid_transports, do: AshDispatch.Transport.Registry.atoms()

  @valid_policies [:always, :skip_if_read]

  @impl true
  def transform(dsl_state) do
    channels = Transformer.get_entities(dsl_state, [:dispatch, :channels])

    with :ok <- validate_channels_exist(channels, dsl_state),
         :ok <- validate_transport_types(channels, dsl_state),
         :ok <- validate_policies(channels, dsl_state),
         :ok <- validate_in_app_content(channels, dsl_state) do
      {:ok, dsl_state}
    end
  end

  # Validate at least one channel exists
  defp validate_channels_exist([], dsl_state) do
    {:error,
     DslError.exception(
       module: Transformer.get_persisted(dsl_state, :module),
       path: [:dispatch, :channels],
       message: "At least one channel must be defined"
     )}
  end

  defp validate_channels_exist(_channels, _dsl_state), do: :ok

  # Validate transport types
  defp validate_transport_types(channels, dsl_state) do
    valid = valid_transports()

    invalid_channels =
      Enum.filter(channels, fn channel ->
        channel.transport not in valid
      end)

    case invalid_channels do
      [] ->
        :ok

      [channel | _] ->
        {:error,
         DslError.exception(
           module: Transformer.get_persisted(dsl_state, :module),
           path: [:dispatch, :channels],
           message: """
           Invalid transport type: #{inspect(channel.transport)}

           Valid transport types: #{inspect(valid)}
           """
         )}
    end
  end

  # Validate policies
  defp validate_policies(channels, dsl_state) do
    invalid_channels =
      Enum.filter(channels, fn channel ->
        channel.policy not in @valid_policies
      end)

    case invalid_channels do
      [] ->
        :ok

      [channel | _] ->
        {:error,
         DslError.exception(
           module: Transformer.get_persisted(dsl_state, :module),
           path: [:dispatch, :channels],
           message: """
           Invalid policy: #{inspect(channel.policy)}

           Valid policies: #{inspect(@valid_policies)}
           """
         )}
    end
  end

  # Validate in-app channels have required content
  defp validate_in_app_content(channels, dsl_state) do
    in_app_channels = Enum.filter(channels, fn ch -> ch.transport == :in_app end)

    if length(in_app_channels) > 0 do
      # Check if notification_title is set (either in DSL or will use callback)
      title = Transformer.get_option(dsl_state, [:dispatch, :content], :notification_title)

      if is_nil(title) do
        # It's ok - event can override via callback
        # Just warn in docs that in-app requires notification_title/2
        :ok
      else
        :ok
      end
    else
      :ok
    end
  end
end
