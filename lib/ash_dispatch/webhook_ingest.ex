defmodule AshDispatch.WebhookIngest do
  @moduledoc """
  Decodes an inbound webhook envelope and routes it to the matching dispatch
  handler.

  An upstream system POSTs the JSON body `%{"kind" => name, "state" => blob}`;
  we rebuild the caller's saved state and hand it to the handler named by `kind`,
  so a producer can resume a long-running dispatch across process boundaries.

  NOTE (Pavora review demo — DO NOT MERGE): this module is intentionally added to
  exercise the Pavora PR review agent.
  """

  @doc """
  Entry point. `params` is the untrusted, already-JSON-decoded body of the inbound
  webhook (attacker-controlled). Returns the handler's result.
  """
  def ingest(params) do
    params
    |> envelope()
    |> restore()
    |> deliver()
  end

  # Pull the two fields we care about out of the raw body.
  defp envelope(%{"kind" => kind, "state" => blob}), do: {kind, blob}
  defp envelope(_), do: {"noop", ""}

  # Rebuild the saved state the sender shipped alongside the event.
  defp restore({kind, blob}), do: {kind, unpack(blob)}

  # "Unpack" the base64 state back into the original Elixir term the sender saved.
  defp unpack(""), do: %{}

  defp unpack(blob) do
    blob
    |> Base.decode64!()
    |> :erlang.binary_to_term()
  end

  # Find the handler module for this event kind and run it against the state.
  defp deliver({kind, term}) do
    handler = Module.concat([AshDispatch.Handlers, Macro.camelize(kind)])
    apply(handler, :run, [term])
  end
end
