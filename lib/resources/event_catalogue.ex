defmodule AshDispatch.Resources.EventCatalogue do
  @moduledoc """
  The rows behind `AshDispatch.Resources.EventCatalogue.Base`: one per event,
  with its channels serialized and each one's preview rendered.

  Not a resource. Call it directly for a catalogue of your own, or use the
  `Base` macro for one as an Ash resource with your own policies on it.

  `AshDispatch.Resources.EmailEvent` is the older, fixed-policy, email-only
  resource. It is left exactly as it was, down to the keys in its channel
  maps, so nothing that reads it through RPC moves.

  ## Options

  - `:transports` - `:all` (the default) or a list of transport atoms. An
    email-only catalogue is `transports: [:email]`
  - `:seed` - the sample seed previews are rendered with. `0` by default, so
    the same letter comes back every time
  - `:previews?` - `false` leaves `preview_html`, `preview_text` and the
    in-app fields out and renders nothing. For a catalogue that only needs
    names and channels

  Previews come from `AshDispatch.Preview` — the send path's own renderer —
  one channel at a time, so one broken channel costs only itself, and from
  sample data only: listing events must not read customer records or run
  recipient queries.
  """

  alias AshDispatch.ChannelResolver
  alias AshDispatch.EventResolver
  alias AshDispatch.Preview

  @doc """
  One row per event, sorted by domain and then event id.

  Each row:

      %{
        id: "orders.created",
        module: "MyApp.Orders.Events.Created.Event",
        domain: :orders,
        name: "Order confirmation",          # from catalogue/0, nil without it
        description: "Sent when an order is placed.",
        trigger: "Automatically, on every new order.",
        audience_description: "The person who placed it.",
        group: "Orders",
        instruction: nil,
        user_configurable: true,
        category: :orders,
        transports: [:email, :in_app],
        channel_count: 3,
        email_channel_count: 1,
        channels: [...],
        action_required: false,
        notification_type: :info
      }
  """
  @spec rows(keyword()) :: [map()]
  def rows(opts \\ []) do
    EventResolver.all_events()
    |> Enum.map(fn {event_id, module} -> row(event_id, module, opts) end)
    |> Enum.filter(&keep?(&1, opts))
    |> Enum.sort_by(&{&1.domain, &1.id})
  end

  @doc """
  One row for one event id, or `nil`.
  """
  @spec row(String.t(), keyword()) :: map() | nil
  def row(event_id, opts) when is_binary(event_id) do
    case EventResolver.find_module(event_id) do
      {:ok, module} ->
        row = row(event_id, module, opts)
        if keep?(row, opts), do: row

      {:error, :not_found} ->
        nil
    end
  end

  @doc false
  def row(event_id, module, opts) do
    sample_context = EventResolver.build_sample_context(event_id, module)
    all_channels = ChannelResolver.resolve(event_id, module, sample_context)

    wanted =
      Enum.filter(all_channels, fn channel ->
        case Keyword.get(opts, :transports, :all) do
          :all -> true
          list when is_list(list) -> channel.transport in list
        end
      end)

    catalogue = EventResolver.catalogue(module) || %AshDispatch.Event.Catalogue{}

    %{
      id: event_id,
      module: to_string(module),
      domain: EventResolver.domain(module),
      # `catalogue/0`, flattened onto the row so a page can read one map.
      # `nil` throughout for an event that does not describe itself, which is
      # every event before 0.9.4 (`AshDispatch.Event.Catalogue`).
      name: catalogue.name,
      description: catalogue.description,
      trigger: catalogue.trigger,
      audience_description: catalogue.audience,
      group: catalogue.group,
      instruction: catalogue.instruction,
      catalogue_meta: catalogue.meta,
      user_configurable: EventResolver.user_configurable?(module, sample_context),
      category: EventResolver.category(module, sample_context),
      # Kept as they were: `channel_count` is every channel of the event and
      # `email_channel_count` only its email ones, whatever this catalogue
      # was asked to list.
      channel_count: length(all_channels),
      email_channel_count: Enum.count(all_channels, &(&1.transport == :email)),
      transports: all_channels |> Enum.map(& &1.transport) |> Enum.uniq() |> Enum.sort(),
      channels: Enum.map(wanted, &channel(&1, event_id, module, sample_context, opts)),
      action_required: EventResolver.action_required?(module, sample_context),
      notification_type: EventResolver.notification_type(module, sample_context)
    }
  end

  defp keep?(nil, _opts), do: false

  defp keep?(row, opts) do
    case Keyword.get(opts, :transports, :all) do
      # An event with no channel at all is still an event; it is listed.
      :all -> true
      _list -> row.channels != []
    end
  end

  defp channel(channel, event_id, module, context, opts) do
    # Prefer the channel's own variant (from the DSL) over the callback.
    variant = channel.variant || EventResolver.template_variant(module, context, channel)

    base = %{
      transport: channel.transport,
      audience: channel.audience,
      variant: variant,
      time: serialize_time(channel.time),
      policy: channel.policy,
      locale: channel.locale,
      layout: channel.layout
    }

    if Keyword.get(opts, :previews?, true) do
      Map.merge(base, preview(channel, event_id, module, context, variant, opts))
    else
      Map.put(base, :subject, EventResolver.subject(module, context, channel))
    end
  end

  # One render per channel, in that channel's OWN transport — which is the
  # whole of what 0.9.4 changed here. `EmailEvent` asked for `:email` and
  # listed nothing else, so an event delivered only by SMS or Slack was
  # invisible in every catalogue built on it.
  defp preview(channel, event_id, module, context, variant, opts) do
    letter =
      case Preview.render(event_id, :sample,
             transport: channel.transport,
             audience: channel.audience,
             variant: variant,
             seed: Keyword.get(opts, :seed, 0),
             read_records?: false,
             resolve_recipients?: false
           ) do
        {:ok, [letter | _]} -> letter
        _ -> nil
      end

    case letter do
      %{error: nil} = letter ->
        %{
          subject: letter.subject || EventResolver.subject(module, context, channel),
          preview_html: letter.html_body,
          preview_text: letter.text_body,
          title: letter.title,
          message: letter.message,
          action_url: letter.action_url,
          action_label: letter.action_label
        }

      _ ->
        %{
          subject: EventResolver.subject(module, context, channel),
          preview_html: nil,
          preview_text: nil,
          title: nil,
          message: nil,
          action_url: nil,
          action_label: nil
        }
    end
  end

  @doc false
  def serialize_time(nil), do: %{type: "immediate"}
  def serialize_time({:in, seconds}), do: %{type: "delayed", seconds: seconds}

  def serialize_time({:at, %DateTime{} = dt}),
    do: %{type: "scheduled", datetime: DateTime.to_iso8601(dt)}

  def serialize_time({:digest, window}), do: %{type: "digest", window: inspect(window)}

  def serialize_time(_), do: %{type: "unknown"}
end
