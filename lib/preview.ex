defmodule AshDispatch.Preview.Rendered do
  @moduledoc """
  One rendered letter from `AshDispatch.Preview.render/3`.

  For an `:email` channel the envelope fields — `:to`, `:from`, `:subject`,
  `:reply_to`, `:html_body`, `:text_body`, `:attachments`, `:headers` — are
  the params the email backend would have been called with, built by the same
  functions the send path uses. For other transports `:title`, `:message`,
  `:action_url` and `:action_label` carry the content and the envelope is
  empty.

  - `:content` - the full content map the receipt would have stored
  - `:recipient` - the identifier the receipt would have been addressed to
    (or the `:recipient_email` override); `nil` when nobody could be resolved
  - `:recipient_name` - the recipient's display name, when configured
  - `:seed` - the seed the sample data was drawn with (`:sample` source only),
    so the same letter can be rendered again
  - `:error` - why the letter could not be rendered, or `nil`. A channel that
    fails renders as a `Rendered` with `:error` set; it never takes the other
    channels down
  """

  @type t :: %__MODULE__{
          event_id: String.t(),
          module: module() | nil,
          transport: atom(),
          audience: atom(),
          variant: atom() | String.t() | nil,
          locale: String.t() | nil,
          channel: AshDispatch.Channel.t(),
          seed: integer() | nil,
          recipient: String.t() | nil,
          recipient_name: String.t() | nil,
          to: String.t() | nil,
          from: String.t() | {String.t(), String.t()} | nil,
          reply_to: String.t() | nil,
          subject: String.t() | nil,
          html_body: String.t() | nil,
          text_body: String.t() | nil,
          attachments: [map()],
          headers: %{String.t() => String.t()},
          title: String.t() | nil,
          message: String.t() | nil,
          action_url: String.t() | nil,
          action_label: String.t() | nil,
          content: map(),
          error: String.t() | nil
        }

  defstruct [
    :event_id,
    :module,
    :transport,
    :audience,
    :variant,
    :locale,
    :channel,
    :seed,
    :recipient,
    :recipient_name,
    :to,
    :from,
    :reply_to,
    :subject,
    :html_body,
    :text_body,
    :title,
    :message,
    :action_url,
    :action_label,
    :error,
    attachments: [],
    headers: %{},
    content: %{}
  ]
end

defmodule AshDispatch.Preview do
  @moduledoc """
  Renders an event exactly as it would be sent — without sending it.

  Two functions:

  - `events/0` — the catalogue: one row per event × channel (transport,
    audience, variant), with the event's metadata. What an admin page lists.
  - `render/3` — one event, rendered from sample data, a stored record or a
    data map of your own, into `AshDispatch.Preview.Rendered` structs.

  ## The same path as the send

  A preview is only worth having if it shows what the recipient gets. So
  there is no preview renderer here: `render/3` opens the event the way the
  send path does (`Dispatcher.prepare/3`, or the notifier's preparation when
  the event is triggered by a resource action), resolves the recipient the
  way the dispatcher does, renders through the function that builds the
  receipt (`Dispatcher.build_receipt/4`), and builds the envelope with the
  email transport's job args and the `SendEmail` worker's backend params.
  What differs is only what is left out: no receipt row, no job, no delivery.

  `AshDispatch.preview/3`, `AshDispatch.Resources.EmailEvent` and the
  ManualTrigger `:preview` action all render through here.

  ## Sources

  - `:sample` (the default) — the event's sample data:
    `sample_data/1` with the seed, falling back on `sample_data/0`. Without
    either, the first record of the event's resource is read instead.
  - `{:record, id}` — the record with that id, from the event's resource. For
    an event triggered by a resource action this runs that action's path in
    full: the event's `load`, `prepare_data/2` (with a bare
    `Ash.Changeset.new(record)`, since there is no action) and the send
    variables.
  - a map — the event's data, taken as it is (what you would pass to
    `Dispatcher.dispatch/3`).

  ## Options

  - `:seed` - seed for `:sample` data. The process's `:rand` state is seeded
    with it for the duration of the render and restored afterwards, so the
    same seed gives the same letter. Without one a seed is drawn and returned
    in `Rendered.seed`, so whatever was shown can be shown again
  - `:transport`, `:audience`, `:variant` - only render matching channels
  - `:locale` - render in this locale, whatever the channel or recipient
    would have chosen
  - `:recipient` - render for this recipient (a user struct or map) instead
    of the first resolved one
  - `:recipient_email` - show this address as the recipient. Only what is
    displayed changes; nothing is sent
  - `:actor` - the actor the event sees, as on an action-triggered send
  - `:authorize?` - read the record (`{:record, id}`, or the fallback for
    `:sample`) with authorization, as `:actor`. Defaults to `false`, as for the
    ManualTrigger resource, which is guarded by its own policies
  - `:variables` - template variables, as the third argument of
    `Dispatcher.dispatch/3`

  ## Example

      {:ok, [letter]} =
        AshDispatch.Preview.render("orders.created", :sample,
          audience: :user,
          seed: 42
        )

      letter.subject
      #=> "Order #4711 confirmed"

  ## What it cannot show

  Whether the letter would be sent at all — `should_send?/2`, the
  recipient's preferences and the `skip_if_read` policy are decided at send
  time — and anything a database read during the send would change, such as
  the link to an in-app notification.
  """

  require Logger

  alias AshDispatch.{ChannelResolver, Context, Dispatcher, EventResolver, Naming}
  alias AshDispatch.Notifier.DispatchHandler
  alias AshDispatch.Preview.Rendered
  alias AshDispatch.Transports.Email
  alias AshDispatch.Workers.SendEmail

  @type source :: :sample | {:record, term()} | map()

  @doc """
  The catalogue: one row per event × channel, sorted by event id.

  Each row:

      %{
        event_id: "orders.created",
        module: MyApp.Orders.Events.Created.Event,
        resource: MyApp.Orders.Order,        # nil for a standalone event module
        domain: :orders,
        trigger_on: :create,                 # nil for a standalone event module
        transport: :email,
        audience: :user,
        variant: nil,
        locales: [],
        time: nil,
        category: :orders,
        user_configurable?: true,
        sensitive?: false,                   # metadata sensitive_content: true
        metadata: [],                        # the event's DSL metadata
        channel: %AshDispatch.Channel{}
      }

  Channels and variants are resolved against the event's sample data (seed
  `0`), the same way the send path resolves them against real data — an
  event whose channels depend on the data lists the ones its sample gives.

  A row can be passed straight to `render/3`: its transport, audience and
  variant become the filters.
  """
  @spec events() :: [map()]
  def events do
    EventResolver.all_events()
    |> Enum.uniq_by(fn {event_id, _module} -> event_id end)
    |> Enum.flat_map(fn {event_id, module} -> event_rows(event_id, module) end)
    |> Enum.sort_by(&{&1.event_id, to_string(&1.transport), to_string(&1.audience)})
  end

  defp event_rows(event_id, module) do
    registry = registry_event(event_id)
    metadata = (registry && registry[:metadata]) || []

    context =
      with_seed(0, fn ->
        %Context{
          event_id: event_id,
          data: EventResolver.sample_data(module, seed: 0),
          metadata: %{}
        }
      end)

    channels =
      ChannelResolver.resolve(event_id, module, context,
        dsl_channels: registry && registry[:channels]
      )

    Enum.map(channels, fn channel ->
      %{
        event_id: event_id,
        module: module,
        resource: registry && registry[:resource],
        domain: EventResolver.domain(module),
        trigger_on: registry && registry[:trigger_on],
        transport: channel.transport,
        audience: channel.audience,
        variant: variant(module, context, channel),
        locales: channel.locales || [],
        time: channel.time,
        category: EventResolver.category(module, context),
        user_configurable?: EventResolver.user_configurable?(module, context) == true,
        sensitive?: Keyword.get(List.wrap(metadata), :sensitive_content, false) == true,
        metadata: metadata,
        channel: channel
      }
    end)
  rescue
    error ->
      Logger.warning("Preview.events/0: skipping #{event_id}: #{Exception.message(error)}")
      []
  end

  @doc """
  Renders an event's channels from `source` without delivering anything.

  `event` is an event id, an event module, or a row from `events/0`. See the
  moduledoc for the sources and options.

  Returns `{:ok, [Rendered.t()]}` — one per matching channel, `[]` when the
  filters match none — or `{:error, reason}` when the event is unknown or its
  data could not be had.
  """
  @spec render(String.t() | module() | map(), source(), keyword()) ::
          {:ok, [Rendered.t()]} | {:error, term()}
  def render(event, source \\ :sample, opts \\ [])

  def render(%{event_id: event_id} = row, source, opts) do
    filters =
      row
      |> Map.take([:transport, :audience, :variant])
      |> Enum.to_list()

    render(event_id, source, Keyword.merge(filters, opts))
  end

  def render(event, source, opts) when is_atom(event) do
    case Enum.find(EventResolver.all_events(), fn {_id, module} -> module == event end) do
      {event_id, _module} -> render(event_id, source, opts)
      nil -> {:error, {:event_module_not_registered, event}}
    end
  end

  def render(event_id, source, opts) when is_binary(event_id) do
    case EventResolver.find_module(event_id) do
      {:ok, module} ->
        seed = seed_for(source, opts)

        with_seed(seed, fn ->
          with {:ok, prepared} <- prepare(event_id, module, source, seed, opts) do
            {:ok,
             prepared.channels
             |> Enum.filter(&matches?(&1, module, prepared.context, opts))
             |> Enum.map(&render_channel(&1, module, prepared, seed, opts))}
          end
        end)

      {:error, :not_found} ->
        {:error, "Event not found: #{event_id}"}
    end
  end

  # ── Opening the event ───────────────────────────────────────────────

  # An event triggered by a resource action is sent by the notifier, which
  # builds its context from the record (resource key, locale, base url, the
  # actor, prepared data). Everything else — manual events, standalone event
  # modules — is sent by `Dispatcher.dispatch/3`. The preview opens the event
  # the way its own send opens it.
  defp prepare(event_id, module, source, seed, opts) do
    variables = Keyword.get(opts, :variables, %{})

    with {:ok, kind, data} <- source_data(event_id, module, source, seed, opts) do
      prepared =
        case action_config(event_id) do
          {config, resource} -> prepare_from_record(config, resource, kind, data, variables, opts)
          nil -> nil
        end

      case prepared do
        nil -> Dispatcher.prepare(event_id, data, variables)
        prepared -> prepared
      end
      |> put_locale(Keyword.get(opts, :locale))
    end
  rescue
    # A preview reports; it does not crash the admin page that asked for it.
    error ->
      Logger.error("Preview of #{event_id} failed to prepare: #{Exception.message(error)}")
      {:error, "Failed to prepare #{event_id}: #{Exception.message(error)}"}
  end

  # Only when the data actually holds a record of the event's resource under
  # its data key — the notifier always has one. Otherwise the event is
  # previewed the way `dispatch/3` would send that data.
  defp prepare_from_record(config, resource, kind, data, variables, opts) do
    data_key = config.event_config[:data_key] || Naming.data_key(resource)

    case Map.get(data, data_key) do
      %{__struct__: ^resource} = record ->
        sample = if kind == :record, do: nil, else: Map.delete(data, data_key)

        {:ok, prepared} =
          DispatchHandler.prepare(record, config, config.event_config,
            actor: Keyword.get(opts, :actor),
            sample: sample
          )

        {:ok, %{prepared | context: merge_variables(prepared.context, variables)}}

      _ ->
        nil
    end
  end

  defp merge_variables(context, variables) when map_size(variables) == 0, do: context

  defp merge_variables(context, variables) do
    %{context | variables: Map.merge(variables, context.variables || %{})}
  end

  defp put_locale({:ok, prepared}, locale) when is_binary(locale) and locale != "" do
    {:ok, %{prepared | context: %{prepared.context | locale: locale}}}
  end

  defp put_locale(result, _locale), do: result

  # The per-action config the notifier dispatches with, if the event is
  # triggered by an action (`trigger_on` other than `:manual`).
  defp action_config(event_id) do
    with %{resource: resource} when not is_nil(resource) <- registry_event(event_id),
         config when not is_nil(config) <-
           resource
           |> AshDispatch.Notifier.Info.all_dispatch_events()
           |> Map.values()
           |> List.flatten()
           |> Enum.find(&(&1.event_id == event_id)) do
      {config, resource}
    else
      _ -> nil
    end
  end

  defp registry_event(event_id) do
    case AshDispatch.EventRegistry.find_event(event_id) do
      {:ok, event} -> event
      _ -> nil
    end
  end

  # ── Sources ─────────────────────────────────────────────────────────

  defp source_data(_event_id, _module, data, _seed, _opts) when is_map(data) do
    {:ok, :map, data}
  end

  defp source_data(event_id, module, :sample, seed, opts) do
    case sample_data(module, seed) do
      {:ok, data} when map_size(data) > 0 ->
        {:ok, :sample, data}

      {:ok, _empty} ->
        # No sample data: read a record instead, as the ManualTrigger preview
        # always has.
        with {:ok, resource, data_key, load} <- record_source(event_id, module),
             {:ok, record} <- read_first(resource, load, opts) do
          {:ok, :record, %{data_key => record}}
        else
          {:error, :no_records} ->
            {:error,
             "No records found and no sample_data/0 or sample_data/1 defined in #{inspect(module)}"}

          {:error, :no_resource} ->
            {:error, "#{inspect(module)} defines no sample data and no resource/0 to read from"}

          error ->
            error
        end

      {:error, _} = error ->
        error
    end
  end

  defp source_data(event_id, module, {:record, id}, _seed, opts) do
    with {:ok, resource, data_key, load} <- record_source(event_id, module) do
      case read(resource, id, load, opts) do
        {:ok, record} ->
          {:ok, :record, %{data_key => record}}

        {:error, error} ->
          Logger.error(
            "Preview: failed to load #{inspect(resource)} #{inspect(id)}: #{inspect(error)}"
          )

          {:error, "Failed to load #{inspect(resource)} with id #{inspect(id)}"}
      end
    else
      {:error, :no_resource} -> {:error, "#{inspect(module)} has no resource to load from"}
    end
  end

  defp source_data(_event_id, _module, source, _seed, _opts) do
    {:error, "Unknown preview source: #{inspect(source)}"}
  end

  defp sample_data(module, seed) do
    data =
      if EventResolver.exports?(module, :sample_data, 1) do
        module.sample_data(seed: seed)
      else
        EventResolver.sample_data(module)
      end

    {:ok, if(is_map(data), do: data, else: %{})}
  rescue
    error ->
      {:error, "sample_data raised in #{inspect(module)}: #{Exception.message(error)}"}
  end

  # The resource, data key and load list for reading the event's record: from
  # the DSL event when there is one, else from the module's callbacks.
  defp record_source(event_id, module) do
    case dsl_event(event_id) do
      {event, resource} ->
        load =
          case action_config(event_id) do
            # The notifier loads the action's (audience-derived) load itself.
            {_config, _resource} -> []
            nil -> event.load || []
          end

        {:ok, resource, event.data_key || Naming.data_key(resource), load}

      nil ->
        case EventResolver.resource(module) do
          nil ->
            {:error, :no_resource}

          resource ->
            data_key = EventResolver.data_key(module) || Naming.data_key(resource)
            {:ok, resource, data_key, module_channel_load(module)}
        end
    end
  end

  defp dsl_event(event_id) do
    with %{resource: resource} when not is_nil(resource) <- registry_event(event_id),
         event when not is_nil(event) <-
           resource
           |> AshDispatch.Resource.Info.events()
           |> Enum.find(&(&1.event_id == event_id)) do
      {event, resource}
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp module_channel_load(module) do
    module
    |> ChannelResolver.get_module_channels(%Context{event_id: "", data: %{}, metadata: %{}})
    |> Enum.flat_map(&(Map.get(&1, :load) || []))
    |> Enum.uniq()
  end

  defp read(resource, id, load, opts) do
    Ash.get(resource, id, [load: load] ++ read_opts(resource, opts))
  end

  defp read_first(resource, load, opts) do
    case Ash.read(resource, [load: load, page: [limit: 1]] ++ read_opts(resource, opts)) do
      {:ok, %{results: [record | _]}} -> {:ok, record}
      {:ok, [record | _]} -> {:ok, record}
      {:ok, _} -> {:error, :no_records}
      error -> error
    end
  end

  defp read_opts(resource, opts) do
    [
      domain: Ash.Resource.Info.domain(resource),
      actor: Keyword.get(opts, :actor),
      authorize?: Keyword.get(opts, :authorize?, false)
    ]
  end

  # ── Channels ────────────────────────────────────────────────────────

  defp matches?(channel, module, context, opts) do
    Enum.all?([:transport, :audience, :variant], fn key ->
      case Keyword.fetch(opts, key) do
        :error ->
          true

        {:ok, nil} when key != :variant ->
          true

        {:ok, wanted} when key == :variant ->
          same_variant?(variant(module, context, channel), wanted)

        {:ok, wanted} ->
          Map.get(channel, key) == wanted
      end
    end)
  end

  defp same_variant?(nil, nil), do: true
  defp same_variant?(nil, _), do: false
  defp same_variant?(_, nil), do: false
  defp same_variant?(a, b), do: to_string(a) == to_string(b)

  # The dispatcher's own precedence: the channel's variant, then the module's.
  defp variant(module, context, channel) do
    channel.variant || EventResolver.template_variant(module, context, channel)
  end

  defp render_channel(channel, module, prepared, seed, opts) do
    channel =
      case Keyword.get(opts, :locale) do
        locale when is_binary(locale) and locale != "" -> %{channel | locale: locale}
        _ -> channel
      end

    base = %Rendered{
      event_id: prepared.context.event_id,
      module: module,
      transport: channel.transport,
      audience: channel.audience,
      variant: variant(module, prepared.context, channel),
      channel: channel,
      seed: seed
    }

    {context, recipient} = recipient(prepared.context, channel, prepared.event_config, opts)

    {_status, attrs} =
      Dispatcher.build_receipt(context, channel, prepared.event_config, recipient)

    recipient_identifier = Keyword.get(opts, :recipient_email) || attrs.recipient

    %{
      base
      | locale: attrs.locale,
        recipient: recipient_identifier && to_string(recipient_identifier),
        recipient_name: AshDispatch.ContentMap.get_content(attrs.content, :recipient_name),
        content: attrs.content
    }
    |> put_envelope(%{attrs | recipient: recipient_identifier}, context, channel)
  rescue
    error ->
      Logger.error(
        "Preview of #{prepared.context.event_id} (#{channel.transport}/#{channel.audience}) " <>
          "failed: #{Exception.message(error)}"
      )

      %Rendered{
        event_id: prepared.context.event_id,
        module: module,
        transport: channel.transport,
        audience: channel.audience,
        variant: channel.variant,
        channel: channel,
        seed: seed,
        recipient: Keyword.get(opts, :recipient_email),
        error: Exception.message(error)
      }
  end

  # The first recipient the dispatcher would have written to. Resolution can
  # read the database (a recipient resolver, an audience query), which sample
  # data is not in — a failure there costs the recipient, not the preview.
  defp recipient(context, channel, event_config, opts) do
    case Keyword.fetch(opts, :recipient) do
      {:ok, recipient} ->
        {context, recipient}

      :error ->
        try do
          case Dispatcher.recipients_for(context, channel, event_config) do
            {context, [first | _]} -> {context, first}
            {context, []} -> {context, nil}
          end
        rescue
          error ->
            Logger.debug("Preview: recipients for #{context.event_id} raised: #{inspect(error)}")
            {context, nil}
        end
    end
  end

  # The envelope, built the way the send builds it: the email transport's job
  # args from the receipt attributes, through JSON as Oban stores them, then
  # the worker's backend params from those args.
  defp put_envelope(rendered, %{transport: :email} = attrs, context, channel) do
    receipt = attrs |> cast_receipt() |> Map.put(:id, nil)

    args =
      receipt
      |> Email.job_args(context, channel)
      |> Jason.encode!()
      |> Jason.decode!()

    params = SendEmail.email_params(receipt, args)

    %{
      rendered
      | to: params.to,
        from: params.from,
        reply_to: params.reply_to,
        subject: params.subject,
        html_body: params.html_body,
        text_body: params.text_body,
        attachments: params.attachments,
        headers: Map.get(params, :headers, %{})
    }
  end

  defp put_envelope(rendered, attrs, _context, _channel) do
    content = attrs.content

    %{
      rendered
      | title: AshDispatch.ContentMap.get_content(content, :title),
        message: AshDispatch.ContentMap.get_content(content, :message),
        action_url: AshDispatch.ContentMap.get_content(content, :action_url),
        action_label: AshDispatch.ContentMap.get_content(content, :action_label)
    }
  end

  # The worker builds its job from the CREATED receipt, so what it sends has
  # been through the receipt resource's casting — an Ash `:string` is trimmed,
  # for one, so a template's final newline never leaves. The preview casts the
  # same attributes through the same resource's `:create`, without creating
  # anything. (The parity test found this: preview and send differed by a
  # trailing "\n".)
  defp cast_receipt(attrs) do
    case AshDispatch.Config.delivery_receipt_resource() do
      nil ->
        attrs

      resource ->
        changeset =
          Ash.Changeset.for_create(resource, :create, attrs,
            skip_unknown_inputs: :*,
            authorize?: false
          )

        Enum.reduce([:recipient, :subject, :body_html, :body_text, :content], attrs, fn key,
                                                                                        acc ->
          if Map.has_key?(changeset.attributes, key),
            do: Map.put(acc, key, Map.get(changeset.attributes, key)),
            else: acc
        end)
    end
  rescue
    _ -> attrs
  end

  # ── Seeding ─────────────────────────────────────────────────────────

  defp seed_for(:sample, opts) do
    case Keyword.get(opts, :seed) do
      seed when is_integer(seed) -> seed
      nil -> :rand.uniform(1_000_000)
      other -> :erlang.phash2(other)
    end
  end

  defp seed_for(_source, opts) do
    case Keyword.get(opts, :seed) do
      seed when is_integer(seed) -> seed
      _ -> nil
    end
  end

  # Seeds the process's `:rand` for `fun`, and puts the previous state back —
  # a preview must not leave a caller's random numbers predictable.
  defp with_seed(nil, fun), do: fun.()

  defp with_seed(seed, fun) do
    previous = :rand.export_seed()
    :rand.seed(:exsss, {seed, seed, seed})

    try do
      fun.()
    after
      case previous do
        :undefined -> Process.delete(:rand_seed)
        state -> :rand.seed(state)
      end
    end
  end
end
