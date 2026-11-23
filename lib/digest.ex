defmodule AshDispatch.Digest do
  @moduledoc """
  Per-recipient digests: several emails to one person, sent as one.

  A channel opts in with a digest time instead of a delay:

      channels: [
        [transport: :email, audience: :user, time: {:digest, {:quiet, 300}}]
      ]

  Its emails are rendered and receipted exactly as before — one receipt per
  recipient, with the full letter in it — but instead of a send job each
  receipt is moved to `:batched` and waits. When the recipient's window is
  due, everything waiting for them goes out together:

    * **one** waiting email is sent as itself, unchanged (`:batched` →
      `:scheduled` → the ordinary send path). A digest of one would only be
      a worse version of the letter that was already written;
    * **two or more** become one digest email with a receipt of its own
      (event id `"ash_dispatch.digest"` by default), and each of them is
      marked `:digested`, pointing at it. A digest is a delivery, not a
      silence: the digest receipt carries the provider id, the webhooks and
      the retries, and every original letter can still be read on its own
      receipt.

  ## Windows

  | Window | Goes out |
  | --- | --- |
  | `{:quiet, seconds}` | once `seconds` have passed without a new email for this recipient — but never later than `digest_max_wait` after the first one (default 30 minutes) |
  | `{:quiet, seconds, max_wait}` | the same, with its own ceiling |
  | `:daily` | at `digest_send_at` (default 07:00) in `digest_time_zone` (default UTC) |
  | `:weekly` | the same, on `digest_week_day` (1 = Monday, the default) |

  `{:quiet, …}` is the one for bursts: five comments in two minutes become
  one email a few minutes after the last.

  ## The person's say

  The configured preference checker may implement
  `c:AshDispatch.UserPreference.user_digest_mode/2` and answer per person and
  category: `:off` (send each email now), `:default` (the channel's window),
  or a window of its own. It is only asked about channels that opted in: an
  event that did not declare a digest time is never delayed, whatever a
  person's setting says, so a login link is never part of a digest.

  ## What is never batched

  An event with `metadata: [sensitive_content: true]`, an event with
  attachments of its own (they live only in the send job's args, and a
  batched email has none), and a manual dispatch with a recipient override
  are always sent at once. The skip and preference rules run when the email
  is batched, exactly when they would have run for an immediate send.

  ## Running it

  Each batched email schedules an `AshDispatch.Workers.FlushDigests` job for
  its recipient at the time the window is due; a newer email moves that job
  instead of adding one. `AshDispatch.Workers.RetryFailedDeliveries` sweeps
  for overdue groups on every run, so a lost job delays a digest by at most
  one retry interval. The jobs run in the `:emails` queue
  (`config :ash_dispatch, digest_queue: …`).

  The digest itself is rendered by `AshDispatch.DigestRenderer` — the
  default is plain and English; a host with a mail design of its own sets
  `config :ash_dispatch, digest_renderer: MyApp.DigestRenderer`. What each
  email contributes to it is `c:AshDispatch.Event.digest_item/2`, or its
  subject and the start of its text body.

  See the *Digests* guide.
  """

  alias AshDispatch.Channel
  alias AshDispatch.Clock
  alias AshDispatch.Config
  alias AshDispatch.ContentMap
  alias AshDispatch.EventResolver
  alias AshDispatch.ReceiptStatus
  alias AshDispatch.Tenancy
  alias AshDispatch.Transports.Email
  alias AshDispatch.Workers.FlushDigests
  alias AshDispatch.Workers.SendEmail

  require Ash.Query
  require Logger

  @typedoc "A digest window, as a channel declares it or a preference answers it."
  @type window ::
          {:quiet, pos_integer()}
          | {:quiet, pos_integer(), pos_integer()}
          | :daily
          | :weekly

  @typedoc "A window with every default filled in."
  @type normalized :: {:quiet, pos_integer(), pos_integer()} | :daily | :weekly

  @summary_length 280
  @sweep_limit 1000
  @zone_warning_key {__MODULE__, :zone_warned}

  # ── Windows ─────────────────────────────────────────────────────────────

  @doc """
  The channel's digest window, normalized, or `nil` when the channel does not
  ask for a digest (or asks for one in a shape this library does not know —
  which is logged, and sent at once).
  """
  @spec channel_window(Channel.t() | map()) :: normalized() | nil
  def channel_window(%{time: {:digest, window}}) do
    case normalize(window) do
      nil ->
        Logger.warning(
          "AshDispatch: unknown digest window #{inspect(window)}; the email is sent at once. " <>
            "Use {:quiet, seconds}, {:quiet, seconds, max_wait}, :daily or :weekly."
        )

        nil

      normalized ->
        normalized
    end
  end

  def channel_window(_channel), do: nil

  @doc "Fills in a window's defaults; `nil` for anything that is not a window."
  @spec normalize(term()) :: normalized() | nil
  def normalize({:quiet, seconds}) when is_integer(seconds) and seconds > 0,
    do: {:quiet, seconds, max(Config.digest_max_wait(), seconds)}

  def normalize({:quiet, seconds, max_wait})
      when is_integer(seconds) and seconds > 0 and is_integer(max_wait) and max_wait >= seconds,
      do: {:quiet, seconds, max_wait}

  def normalize(:daily), do: :daily
  def normalize(:weekly), do: :weekly
  def normalize(_other), do: nil

  @doc """
  The window as the string stored on a batched receipt and carried by its
  flush job. Emails for one recipient are grouped by it.
  """
  @spec key(normalized()) :: String.t()
  def key({:quiet, seconds, max_wait}), do: "quiet:#{seconds}:#{max_wait}"
  def key(:daily), do: "daily"
  def key(:weekly), do: "weekly"

  @doc "The window a key stands for, or `nil`."
  @spec parse_key(String.t() | nil) :: normalized() | nil
  def parse_key("daily"), do: :daily
  def parse_key("weekly"), do: :weekly

  def parse_key("quiet:" <> rest) do
    with [seconds, max_wait] <- String.split(rest, ":"),
         {seconds, ""} <- Integer.parse(seconds),
         {max_wait, ""} <- Integer.parse(max_wait) do
      normalize({:quiet, seconds, max_wait})
    else
      _ -> nil
    end
  end

  def parse_key(_other), do: nil

  @doc """
  When a group of batched emails is due, given when each was batched.

  `{:quiet, s, max}`: `s` after the newest, but no later than `max` after the
  oldest. `:daily` / `:weekly`: the first send time after the oldest.
  """
  @spec due_at(normalized(), [DateTime.t(), ...]) :: DateTime.t()
  def due_at({:quiet, seconds, max_wait}, [_ | _] = batched_at) do
    newest = Enum.max(batched_at, DateTime)
    oldest = Enum.min(batched_at, DateTime)

    Enum.min([DateTime.add(newest, seconds), DateTime.add(oldest, max_wait)], DateTime)
  end

  def due_at(calendar, [_ | _] = batched_at) when calendar in [:daily, :weekly] do
    next_send_time(calendar, Enum.min(batched_at, DateTime))
  end

  @doc """
  The first daily or weekly send time strictly after `after_dt`, in UTC.

  Read in `digest_time_zone`. Without a time zone database that knows the
  zone (`config :elixir, :time_zone_database`), the send time is read in UTC
  and a warning is logged once.
  """
  @spec next_send_time(:daily | :weekly, DateTime.t()) :: DateTime.t()
  def next_send_time(calendar, %DateTime{} = after_dt) do
    zone = Config.digest_time_zone()
    send_at = Config.digest_send_at()
    local_date = after_dt |> in_zone(zone) |> DateTime.to_date()

    first =
      case calendar do
        :daily ->
          local_date

        :weekly ->
          ahead = rem(Config.digest_week_day() - Date.day_of_week(local_date) + 7, 7)
          Date.add(local_date, ahead)
      end

    step = if calendar == :daily, do: 1, else: 7
    candidate = at_local(first, send_at, zone)

    if DateTime.compare(candidate, after_dt) == :gt,
      do: candidate,
      else: at_local(Date.add(first, step), send_at, zone)
  end

  defp in_zone(dt, "Etc/UTC"), do: dt

  defp in_zone(dt, zone) do
    case DateTime.shift_zone(dt, zone) do
      {:ok, local} ->
        local

      {:error, reason} ->
        warn_zone(zone, reason)
        dt
    end
  end

  defp at_local(date, time, zone) do
    result =
      case DateTime.new(date, time, zone) do
        {:ok, dt} -> dt
        # The clock jumps forward over the send time: the first moment after.
        {:gap, _before, just_after} -> just_after
        # The send time happens twice: the first of them.
        {:ambiguous, first, _second} -> first
        {:error, reason} -> warn_zone(zone, reason) && DateTime.new!(date, time, "Etc/UTC")
      end

    DateTime.shift_zone!(result, "Etc/UTC")
  end

  defp warn_zone(zone, reason) do
    unless :persistent_term.get(@zone_warning_key, false) do
      :persistent_term.put(@zone_warning_key, true)

      Logger.warning(
        "AshDispatch: digest_time_zone #{inspect(zone)} could not be used (#{inspect(reason)}); " <>
          "daily and weekly digests go out at digest_send_at in UTC. Configure a time zone " <>
          "database, e.g. `config :elixir, :time_zone_database, Tz.TimeZoneDatabase`."
      )
    end

    true
  end

  # ── Deciding and batching (called by the email transport) ──────────────

  @doc false
  # The window this receipt waits in, or `nil` to send it now. Called by
  # `AshDispatch.Transports.Email` after the preference gate has let the
  # email through.
  @spec window_for(map(), map(), Channel.t(), keyword() | map()) :: normalized() | nil
  def window_for(receipt, context, channel, event_config) do
    with window when not is_nil(window) <- channel_window(channel),
         :email <- Map.get(channel, :transport),
         true <- batchable?(receipt),
         nil <- AshDispatch.Dispatcher.override(context),
         false <- Email.sensitive?(Map.get(context, :event_id)),
         [] <- Email.event_attachments(context, channel) do
      AshDispatch.UserPreference.digest_window(receipt, context, channel, event_config, window)
    else
      _ -> nil
    end
  end

  # A receipt resource of the host's own, not built on `DeliveryReceipt.Base`,
  # may have no `:batch` action. Batching it would fail and leave the email
  # `:pending` with no job — lost. It is sent at once instead, and the host
  # is told once why its digest channel does not digest.
  defp batchable?(%resource{}) do
    if Ash.Resource.Info.resource?(resource) and Ash.Resource.Info.action(resource, :batch) do
      true
    else
      key = {__MODULE__, :unbatchable, resource}

      unless :persistent_term.get(key, false) do
        :persistent_term.put(key, true)

        Logger.warning(
          "AshDispatch: #{inspect(resource)} has no :batch action, so emails on digest " <>
            "channels are sent at once. Build the receipt on DeliveryReceipt.Base, or add " <>
            ":batch, :release and :mark_digested actions."
        )
      end

      false
    end
  end

  defp batchable?(_receipt), do: false

  @doc false
  # Moves a pending email receipt to `:batched` and (re)schedules its
  # recipient's flush. Returns `{:ok, receipt}` like a transport.
  @spec batch(struct(), normalized(), map(), Channel.t()) :: {:ok, struct()} | {:error, term()}
  def batch(receipt, window, context, channel) do
    digest = %{
      "window" => key(window),
      "batched_at" => DateTime.to_iso8601(Clock.utc_now()),
      "item" => item(context, channel, receipt)
    }

    case ReceiptStatus.batch(receipt, digest) do
      {:ok, batched} ->
        schedule_flush(batched, window)
        {:ok, batched}

      {:error, error} ->
        Logger.error("Receipt #{receipt.id} could not be batched: #{inspect(error)}")
        {:error, error}
    end
  end

  @doc false
  # What this email contributes to a digest: the event's `digest_item/2`, over
  # the defaults (its subject, and the start of its text body). Stored on the
  # receipt when it is batched, so the digest is rendered from what the event
  # said at the time, like every other letter.
  @spec item(map(), Channel.t(), map()) :: map()
  def item(context, channel, receipt) do
    defaults = %{
      "title" => Map.get(receipt, :subject),
      "summary" => summary(Map.get(receipt, :body_text)),
      "url" => nil
    }

    custom =
      case EventResolver.find_module(Map.get(context, :event_id)) do
        {:ok, module} -> EventResolver.digest_item(module, context, channel)
        _ -> %{}
      end

    Map.merge(defaults, stringify(custom))
  end

  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp stringify(_), do: %{}

  defp summary(nil), do: nil

  defp summary(text) when is_binary(text) do
    text
    |> String.split(~r/\n\s*\n/, trim: true)
    |> Enum.map(&(&1 |> String.replace(~r/\s+/, " ") |> String.trim()))
    |> Enum.find(&(&1 != ""))
    |> case do
      nil -> nil
      paragraph -> truncate(paragraph)
    end
  end

  defp truncate(text) do
    if String.length(text) > @summary_length,
      do: String.slice(text, 0, @summary_length - 1) <> "…",
      else: text
  end

  defp schedule_flush(receipt, window) do
    tenant = Tenancy.of(receipt)
    entries = group(receipt.recipient, key(window), tenant)
    due = due_at(window, Enum.map(entries, &batched_at/1))

    FlushDigests.job(receipt.recipient, key(window), Tenancy.receipt_prefix(tenant), due)
    |> Oban.insert()
    |> case do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Digest flush for receipt #{receipt.id} could not be scheduled (#{inspect(reason)}); " <>
            "the retry sweep sends it once it is due"
        )
    end
  rescue
    error ->
      Logger.warning(
        "Digest flush for receipt #{receipt.id} could not be scheduled " <>
          "(#{Exception.message(error)}); the retry sweep sends it once it is due"
      )
  end

  # ── Flushing (called by FlushDigests and the sweep) ─────────────────────

  @doc """
  Sends what is waiting for one recipient in one window, if it is due.

  Returns `:ok`, or `{:snooze, seconds}` when the window is not due yet (the
  flush job's answer to Oban). Options: `force: true` sends regardless of the
  window (tests, an admin's "send now").
  """
  @spec flush(String.t(), String.t(), term(), keyword()) ::
          :ok | {:snooze, pos_integer()} | {:error, term()}
  def flush(recipient, window_key, tenant \\ nil, opts \\ []) do
    entries = group(recipient, window_key, tenant)

    case entries do
      [] ->
        :ok

      entries ->
        now = Keyword.get(opts, :now) || Clock.utc_now()
        due = due(window_key, entries)

        if Keyword.get(opts, :force, false) or DateTime.compare(now, due) != :lt do
          result = send_group(entries, tenant)
          schedule_rest(recipient, window_key, tenant, Enum.map(entries, & &1.id))
          result
        else
          {:snooze, max(DateTime.diff(due, now), 1)}
        end
    end
  end

  @doc """
  Sends every group in `tenant` that is due (`force: true`: every group).

  The safety net behind the per-recipient flush jobs, run by
  `AshDispatch.Workers.RetryFailedDeliveries` and by `FlushDigests` without
  a recipient. A group that is not due is left alone: its own job is coming.
  """
  @spec sweep(term(), keyword()) :: :ok
  def sweep(tenant \\ nil, opts \\ []) do
    resource = Config.delivery_receipt_resource()

    resource
    |> Ash.Query.filter(status == :batched and transport == :email)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.limit(@sweep_limit)
    |> Ash.read!([authorize?: false] ++ Tenancy.opts(resource, tenant))
    |> Enum.group_by(&{&1.recipient, window_key(&1)})
    |> Enum.each(fn {{recipient, window_key}, _entries} ->
      case flush(recipient, window_key, tenant, opts) do
        :ok -> :ok
        {:snooze, _} -> :ok
        {:error, reason} -> Logger.error("Digest sweep: #{inspect(reason)}")
      end
    end)
  rescue
    error ->
      Logger.error("Digest sweep failed: #{Exception.message(error)}")
      :ok
  end

  # An email batched while this flush was reading may have found the flush
  # job already running, and unique jobs gave it no job of its own. Whatever
  # is still waiting in this window now gets one.
  defp schedule_rest(recipient, window_key, tenant, flushed_ids) do
    case Enum.reject(group(recipient, window_key, tenant), &(&1.id in flushed_ids)) do
      [] ->
        :ok

      rest ->
        recipient
        |> FlushDigests.job(window_key, Tenancy.receipt_prefix(tenant), due(window_key, rest))
        |> Oban.insert()

        :ok
    end
  rescue
    error ->
      Logger.warning("Digest: could not reschedule the rest (#{Exception.message(error)})")
      :ok
  end

  defp due(window_key, entries) do
    case parse_key(window_key) do
      nil -> Clock.utc_now()
      window -> due_at(window, Enum.map(entries, &batched_at/1))
    end
  end

  # What is waiting for this address in this window, oldest first.
  defp group(recipient, window_key, tenant) do
    resource = Config.delivery_receipt_resource()

    resource
    |> Ash.Query.filter(status == :batched and transport == :email and recipient == ^recipient)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!([authorize?: false] ++ Tenancy.opts(resource, tenant))
    |> Enum.filter(&(window_key(&1) == window_key))
    |> Enum.map(&Tenancy.remember(&1, tenant))
  end

  defp digest_content(receipt), do: ContentMap.get_content(Map.get(receipt, :content), :digest)

  defp window_key(receipt) do
    case digest_content(receipt) do
      %{} = digest -> digest["window"] || digest[:window]
      _ -> nil
    end
  end

  defp batched_at(receipt) do
    with %{} = digest <- digest_content(receipt),
         at when is_binary(at) <- digest["batched_at"] || digest[:batched_at],
         {:ok, dt, _offset} <- DateTime.from_iso8601(at) do
      dt
    else
      _ -> to_datetime(Map.get(receipt, :inserted_at))
    end
  end

  defp to_datetime(%DateTime{} = dt), do: dt
  defp to_datetime(%NaiveDateTime{} = naive), do: DateTime.from_naive!(naive, "Etc/UTC")
  defp to_datetime(_), do: Clock.utc_now()

  defp send_group(entries, tenant) do
    case Enum.reject(entries, &read_already?/1) do
      [] -> :ok
      [single] -> release(single)
      many -> send_digest(many, tenant)
    end
  end

  # `policy: :skip_if_read` keeps its meaning while the email waits: read in
  # the app before the digest goes out, and it is left out of it.
  defp read_already?(receipt) do
    case SendEmail.skip_if_read_reason(receipt) do
      nil ->
        false

      reason ->
        ReceiptStatus.skip(receipt, reason)
        true
    end
  end

  # One email waiting: it goes out as itself, through the ordinary send path.
  defp release(receipt) do
    case receipt |> SendEmail.new_for_receipt(Email.default_attachment_args()) |> Oban.insert() do
      {:ok, job} ->
        with {:ok, current} <- reread(receipt),
             :batched <- current.status do
          ReceiptStatus.release(current, oban_job_id: job.id)
        end

        :ok

      {:error, reason} ->
        Logger.error("Digest: could not enqueue receipt #{receipt.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp send_digest(entries, tenant) do
    case create_digest(entries, tenant) do
      {:ok, digest} ->
        case digest
             |> SendEmail.new_for_receipt(Email.default_attachment_args())
             |> Oban.insert() do
          {:ok, job} ->
            with {:ok, current} <- reread(digest), :pending <- current.status do
              ReceiptStatus.mark_scheduled(current,
                oban_job_id: job.id,
                scheduled_for: job.scheduled_at
              )
            end

            :ok

          {:error, reason} ->
            # The digest receipt exists and holds the letter; without a job it
            # is a pending receipt, which the send-now and retry machinery can
            # see. Report it rather than pretend.
            Logger.error("Digest #{digest.id} could not be enqueued: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error(
          "Digest for #{length(entries)} emails could not be created: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # The digest receipt and the entries' move to `:digested`, together: an
  # entry another flush got to first fails its transition and takes the whole
  # digest back with it, so no letter is ever in two digests.
  defp create_digest(entries, tenant) do
    transaction(fn ->
      with {:ok, digest} <- create_digest_receipt(entries, tenant),
           :ok <- mark_digested(entries, digest) do
        digest
      else
        {:error, reason} -> rollback(reason)
      end
    end)
  end

  defp create_digest_receipt([first | _] = entries, tenant) do
    rendered = render(entries)
    content = Map.get(first, :content) || %{}

    resource = Config.delivery_receipt_resource()

    attrs =
      %{
        event_id: Config.digest_event_id(),
        transport: :email,
        audience: first.audience,
        recipient: first.recipient,
        user_id: Map.get(first, :user_id),
        locale: Map.get(first, :locale),
        subject: rendered.subject,
        body_html: rendered.html_body,
        body_text: rendered.text_body,
        content: %{
          "subject" => rendered.subject,
          "html_body" => rendered.html_body,
          "text_body" => rendered.text_body,
          "from" =>
            storable_from(Map.get(rendered, :from) || ContentMap.get_content(content, :from)),
          "reply_to" =>
            Map.get(rendered, :reply_to) || ContentMap.get_content(content, :reply_to),
          "digest" => %{
            "window" => window_key(first),
            "entries" => Enum.map(entries, & &1.id),
            "count" => length(entries)
          }
        }
      }
      |> maybe_put(:tenant, tenant_column(first))

    resource
    |> Ash.Changeset.for_create(:create, attrs, skip_unknown_inputs: [:tenant, :locale])
    |> Tenancy.set(tenant)
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, digest} -> {:ok, Tenancy.remember(digest, tenant)}
      other -> other
    end
  end

  defp tenant_column(receipt), do: Map.get(receipt, :tenant)

  # The content is a JSONB column: a `{name, email}` tuple cannot be stored,
  # so it is kept as the map the email transport stores, which the worker
  # reads back as the same tuple.
  defp storable_from({name, email}) when is_binary(email), do: %{"name" => name, "email" => email}
  defp storable_from(from), do: from

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp mark_digested(entries, digest) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case ReceiptStatus.mark_digested(entry, digest.id) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp render(entries) do
    items =
      Enum.map(entries, fn entry ->
        item =
          case digest_content(entry) do
            %{} = digest -> digest["item"] || digest[:item] || %{}
            _ -> %{}
          end

        item
        |> stringify()
        |> Map.put_new("title", entry.subject)
        |> Map.put("event_id", entry.event_id)
        |> Map.put("receipt_id", entry.id)
        |> Map.put("batched_at", batched_at(entry))
      end)

    [first | _] = entries

    info = %{
      recipient: first.recipient,
      user_id: Map.get(first, :user_id),
      locale: Map.get(first, :locale),
      count: length(entries)
    }

    rendered = Config.digest_renderer().render(items, info)

    %{
      subject: Map.fetch!(rendered, :subject),
      html_body: Map.get(rendered, :html_body),
      text_body: Map.get(rendered, :text_body),
      from: Map.get(rendered, :from),
      reply_to: Map.get(rendered, :reply_to)
    }
  end

  defp transaction(fun) do
    case Config.repo() do
      nil ->
        try do
          {:ok, fun.()}
        catch
          {:digest_rollback, reason} -> {:error, reason}
        end

      repo ->
        repo.transaction(fn ->
          try do
            fun.()
          catch
            {:digest_rollback, reason} -> repo.rollback(reason)
          end
        end)
    end
  end

  defp rollback(reason), do: throw({:digest_rollback, reason})

  defp reread(receipt) do
    resource = receipt.__struct__
    tenant = Tenancy.of(receipt)

    case Ash.get(resource, receipt.id, [authorize?: false] ++ Tenancy.opts(resource, tenant)) do
      {:ok, current} -> {:ok, Tenancy.remember(current, tenant)}
      other -> other
    end
  end
end
