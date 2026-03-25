defmodule AshDispatch.Transports.Broadcast do
  @moduledoc """
  Lightweight PubSub broadcast transport for real-time events.

  Broadcasts event payload directly to a Phoenix channel without
  creating Notification records. Uses the same `pubsub_module` and
  `channel_topic` config as other transports — everything config-derived.

  Receipt is created (audit trail) and immediately marked as sent.

  ## Channel Config

      [transport: :broadcast, audience: :user]
      [transport: :broadcast, audience: :admin]

  Admin audience broadcasts to the firehose topic configured via
  `:admin_channel_topic` (default: "admin:firehose").
  """

  alias AshDispatch.Config
  import AshDispatch.ContentMap

  require Logger

  @doc "Delivers a broadcast event to user or admin PubSub channel."
  def deliver(receipt, context, channel, _event_config) do
    pubsub = Config.pubsub_module()

    if is_nil(pubsub) do
      Logger.warning("Broadcast transport: no pubsub_module configured, skipping")
      {:ok, maybe_mark_skipped(receipt, "no_pubsub_module")}
    else
      payload = build_payload(receipt, context)
      event_name = derive_event_name(context.event_id)

      result =
        case channel.audience do
          :admin ->
            admin_topic = Config.admin_channel_topic()
            pubsub.broadcast(admin_topic, event_name, payload)

          _ ->
            if receipt.user_id do
              topic = "#{Config.channel_topic()}:#{receipt.user_id}"
              pubsub.broadcast(topic, event_name, payload)
            else
              :no_user_id
            end
        end

      case result do
        :ok -> {:ok, maybe_mark_sent(receipt)}
        :no_user_id -> {:ok, maybe_mark_skipped(receipt, "no_user_id")}
        {:error, reason} -> {:ok, maybe_mark_failed(receipt, inspect(reason))}
      end
    end
  rescue
    e ->
      Logger.error("Broadcast transport error: #{inspect(e)}")
      {:error, e}
  end

  defp build_payload(receipt, context) do
    base = Map.merge(context.data || %{}, context.variables || %{})
    content = receipt.content || %{}

    base
    |> maybe_put(:title, get_content(content, :title))
    |> maybe_put(:message, get_content(content, :message))
    |> Map.put(:timestamp, (context.now || DateTime.utc_now()) |> DateTime.to_iso8601())
  end

  # "pipeline_events.chat_chunk" → "chat_chunk"
  defp derive_event_name(event_id) do
    event_id |> to_string() |> String.split(".") |> List.last()
  end

  # Handle both real receipts (Ash structs) and pseudo-receipts (plain maps)
  defp maybe_mark_sent(%{id: nil} = receipt), do: receipt
  defp maybe_mark_sent(receipt) do
    receipt |> Ash.Changeset.for_update(:mark_sent, %{}) |> Ash.update!()
  end

  defp maybe_mark_skipped(%{id: nil} = receipt, _reason), do: receipt
  defp maybe_mark_skipped(receipt, reason) do
    receipt |> Ash.Changeset.for_update(:skip, %{error_message: reason}) |> Ash.update!()
  end

  defp maybe_mark_failed(%{id: nil} = receipt, _reason), do: receipt
  defp maybe_mark_failed(receipt, reason) do
    receipt |> Ash.Changeset.for_update(:mark_failed, %{error_message: reason}) |> Ash.update!()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)
end
