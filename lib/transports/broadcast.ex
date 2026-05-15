defmodule AshDispatch.Transports.Broadcast do
  use AshDispatch.Transport, atom: :broadcast, skip_receipt?: true

  @moduledoc """
  Lightweight PubSub broadcast transport for real-time events.

  Broadcasts event payload directly to a Phoenix channel without
  creating Notification records. Uses the same `pubsub_module` and
  `channel_topic` config as other transports — everything config-derived.

  Receipt is created (audit trail) and immediately marked as sent.

  ## Features

  - `invalidates` — event-declared frontend cache keys included in payload
  - `throttle_ms` — per-user+event rate limiting via ETS (metadata option)

  ## Channel Config

      [transport: :broadcast, audience: :user]
      [transport: :broadcast, audience: :admin]

  Admin audience broadcasts to the firehose topic configured via
  `:admin_channel_topic` (default: "admin:firehose").
  """

  alias AshDispatch.Config
  import AshDispatch.ContentMap

  require Logger

  # ETS table for per-user+event throttle tracking. Created lazily.
  @throttle_table :ash_dispatch_broadcast_throttle

  @doc "Delivers a broadcast event to user or admin PubSub channel."
  def deliver(receipt, context, channel, event_config) do
    pubsub = Config.pubsub_module()

    if is_nil(pubsub) do
      # `pubsub_module: nil` is the documented passive-shell posture
      # (test mode / boot-without-Endpoint). Per-event warning here
      # floods logs in the test suite where every dispatch hits this
      # branch; consumers who want a startup-time presence check
      # should call `Config.pubsub_module()` from their app boot.
      {:ok, maybe_mark_skipped(receipt, "no_pubsub_module")}
    else
      throttle_ms = get_in(event_config, [:metadata, :throttle_ms])

      if throttle_ms && throttled?(context.event_id, receipt.user_id, throttle_ms) do
        {:ok, maybe_mark_skipped(receipt, "throttled")}
      else
        do_deliver(receipt, context, channel, event_config, pubsub)
      end
    end
  rescue
    e ->
      Logger.error("Broadcast transport error: #{inspect(e)}")
      {:error, e}
  end

  defp do_deliver(receipt, context, channel, event_config, pubsub) do
    payload = build_payload(receipt, context, event_config)
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

  defp build_payload(receipt, context, event_config) do
    base = Map.merge(context.data || %{}, context.variables || %{})
    content = receipt.content || %{}
    invalidates = event_config[:invalidates] || []
    metadata = event_config[:metadata] || []

    # Include toast rendering hints from metadata if present
    toast_fields =
      metadata
      |> Keyword.take([:toast_variant, :toast_duration, :toast_sound])
      |> Enum.into(%{})

    base
    |> maybe_put(:title, get_content(content, :title))
    |> maybe_put(:message, get_content(content, :message))
    |> maybe_put(:invalidates, if(invalidates != [], do: invalidates))
    |> maybe_put(:toast, if(toast_fields != %{}, do: toast_fields))
    |> Map.put(:timestamp, (context.now || DateTime.utc_now()) |> DateTime.to_iso8601())
  end

  # ── Throttle ──────────────────────────────────────────────────

  defp throttled?(event_id, user_id, throttle_ms) do
    ensure_throttle_table()
    key = {event_id, user_id}
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@throttle_table, key) do
      [{^key, last_sent}] when now - last_sent < throttle_ms ->
        true

      _ ->
        :ets.insert(@throttle_table, {key, now})
        false
    end
  end

  defp ensure_throttle_table do
    case :ets.whereis(@throttle_table) do
      :undefined ->
        :ets.new(@throttle_table, [:set, :public, :named_table, read_concurrency: true])

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  # ── Helpers ───────────────────────────────────────────────────

  # F15 (review-deep 2026-05-15) — wire-event-name derivation moved
  # to `AshDispatch.Naming.wire_event_name/1`. Per-event override is
  # available via the `wire_event_name/0` callback on `AshDispatch.Event`
  # (default impl in __using__: split-and-last); transports route here
  # so the convention stays centralized.
  defp derive_event_name(event_id) do
    AshDispatch.Naming.wire_event_name(event_id)
  end

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
