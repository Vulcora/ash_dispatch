defmodule AshDispatch.Channel do
  @moduledoc """
  Represents a delivery channel for an event.

  A channel specifies:
  - **Transport** - How to deliver (email, in_app, discord, etc.)
  - **Audience** - Who receives (:user, :admin, custom)
  - **Time** - When to deliver (immediate, delayed, scheduled)
  - **Policy** - Delivery policy (:always, :skip_if_read)
  - **Variant** - Template variant (e.g., :admin for admin-specific templates)
  - **Layout** - Which layout wraps the rendered body (`layout`, or
    `layout_from` to read it off the record)
  - **Queue** - Which Oban queue this channel's send job runs in, instead of
    the transport's

  ## Layout

  `layout: :urgent` renders through
  `priv/ash_dispatch/layouts/urgent/email.html.heex`, falling back on
  `priv/ash_dispatch/layouts/email.html.heex` when that subdirectory has no
  layout for the format. `layout_from: :brand` reads the name off the event's
  record instead, which is how one installation sends each brand's mail in its
  own frame. Unset — which is every channel that does not say otherwise — the
  default layout is used, exactly as before.

  A layout name is a directory name, so only letters, digits, `_`, `-` and
  `.` are accepted; anything else is ignored with a warning rather than joined
  into a path.

  ## Time

  - `:immediate` (or `{:in, 0}`) — deliver now
  - `{:in, seconds}` — deliver after a relative delay
  - `{:at, %DateTime{}}` — deliver at an absolute time (a time in the past
    means now)
  - `{:digest, window}` — email only: hold it for the recipient's digest,
    sent when the window is due — `{:quiet, seconds}`, `{:quiet, seconds,
    max_wait}`, `:daily` or `:weekly`. See `AshDispatch.Digest`
  - `{:window, map}` — **deprecated**, delivers immediately

  Only asynchronous transports honour the delay; `:in_app` writes its
  notification synchronously.

  ## Examples

      %Channel{
        transport: :email,
        audience: :user,
        time: {:in, 300},  # Delay 5 minutes
        policy: :skip_if_read
      }

      %Channel{
        transport: :email,
        audience: :user,
        time: {:at, ~U[2026-09-01 07:00:00Z]}  # Deliver at an absolute time
      }

      %Channel{
        transport: :discord,
        audience: :admin,
        time: :immediate,
        opts: %{webhook_url: "https://..."}
      }
  """

  require Logger

  @window_deprecation_key {__MODULE__, :window_deprecation_warned}

  @type transport :: :email | :in_app | :discord | :sms | :slack | :webhook | atom()
  @type audience :: :user | :admin | atom()
  # `{:window, map()}` is DEPRECATED — business-hours windows were never
  # implemented and the spec has always delivered immediately. It still
  # does, and now logs a deprecation warning once per boot.
  @type time ::
          :immediate
          | {:in, non_neg_integer()}
          | {:at, DateTime.t()}
          | {:digest, AshDispatch.Digest.window()}
          | {:window, map()}
  @type policy :: :always | :skip_if_read | {:gate, function()}
  @type variant :: atom() | nil
  @type layout :: atom() | String.t() | nil

  @type t :: %__MODULE__{
          transport: transport(),
          audience: audience(),
          time: time(),
          policy: policy(),
          variant: variant(),
          locale: String.t() | nil,
          locale_from: atom() | nil,
          locales: [String.t()],
          layout: layout(),
          layout_from: atom() | nil,
          queue: atom() | nil,
          webhook_url: String.t() | nil,
          content: map(),
          metadata: map(),
          opts: map(),
          load: [atom() | {atom(), any()}],
          deduplicate_group: atom() | nil,
          idempotency_source: atom() | nil,
          optional: boolean(),
          exclude_actor: boolean()
        }

  @enforce_keys [:transport, :audience]
  defstruct [
    :transport,
    :audience,
    :variant,
    :locale,
    :locale_from,
    :layout,
    :layout_from,
    :queue,
    :webhook_url,
    :deduplicate_group,
    :idempotency_source,
    time: {:in, 0},
    policy: :always,
    optional: false,
    exclude_actor: false,
    content: %{},
    metadata: %{},
    opts: %{},
    load: [],
    locales: []
  ]

  @doc """
  Creates a new channel.

  ## Examples

      iex> Channel.new(:email, :user)
      %Channel{transport: :email, audience: :user, time: {:in, 0}}

      iex> Channel.new(:email, :user, time: 5.minutes(), skip_if_read: true)
      %Channel{
        transport: :email,
        audience: :user,
        time: {:in, 300},
        policy: :skip_if_read
      }
  """
  def new(transport, audience, opts \\ []) do
    time = Keyword.get(opts, :time, {:in, 0})
    policy = if Keyword.get(opts, :skip_if_read), do: :skip_if_read, else: :always

    # Every field of the struct a caller can name, not a hand-picked few: this
    # function built a channel without `locale`, `layout` or `queue` even when
    # asked for them, so a `channels/1` callback using it silently lost what
    # the inline DSL carried. `Keyword.get/2` for each, so a caller that names
    # none gets exactly the struct it got before.
    %__MODULE__{
      transport: transport,
      audience: audience,
      time: normalize_time(time),
      policy: Keyword.get(opts, :policy, policy),
      variant: Keyword.get(opts, :variant),
      locale: Keyword.get(opts, :locale),
      locale_from: Keyword.get(opts, :locale_from),
      locales: Keyword.get(opts, :locales, []),
      layout: Keyword.get(opts, :layout),
      layout_from: Keyword.get(opts, :layout_from),
      queue: Keyword.get(opts, :queue),
      webhook_url: Keyword.get(opts, :webhook_url),
      deduplicate_group: Keyword.get(opts, :deduplicate_group),
      idempotency_source: Keyword.get(opts, :idempotency_source),
      optional: Keyword.get(opts, :optional, false),
      exclude_actor: Keyword.get(opts, :exclude_actor, false),
      content: Keyword.get(opts, :content, %{}),
      metadata: Keyword.get(opts, :metadata, %{}),
      load: Keyword.get(opts, :load, []),
      opts: Keyword.get(opts, :opts, %{})
    }
  end

  @doc """
  Helper function to create a channel struct.
  Used in DSL and event modules for cleaner syntax.

  ## Examples

      def channels(_ctx) do
        [
          channel(:in_app, :user),
          channel(:email, :user, time: 5.minutes(), skip_if_read: true)
        ]
      end
  """
  def channel(transport, audience, opts \\ []) do
    new(transport, audience, opts)
  end

  @doc """
  Normalizes time specification to internal format.

  ## Examples

      iex> Channel.normalize_time(:immediate)
      {:in, 0}

      iex> Channel.normalize_time(300)
      {:in, 300}

      iex> Channel.normalize_time({:in, 300})
      {:in, 300}
  """
  def normalize_time(:immediate), do: {:in, 0}
  def normalize_time(seconds) when is_integer(seconds), do: {:in, seconds}
  def normalize_time({:in, _} = time), do: time
  def normalize_time({:at, %DateTime{}} = time), do: time
  def normalize_time({:window, _} = time), do: time
  def normalize_time({:digest, _} = time), do: time
  def normalize_time(time), do: time

  @doc """
  Calculates delay in seconds from time specification.

  For `{:at, datetime}` the result is relative to now and may be negative
  when the datetime is in the past; callers that schedule work clamp it at
  zero (see `AshDispatch.Transports.Email`).

  `{:window, map}` is deprecated and always returns `0` (immediate) — see
  `warn_window_deprecated/0`.

  ## Examples

      iex> Channel.calculate_delay(%Channel{transport: :email, audience: :user, time: {:in, 300}})
      300

      iex> Channel.calculate_delay(%Channel{transport: :email, audience: :user, time: :immediate})
      0
  """
  def calculate_delay(%__MODULE__{time: {:in, seconds}}), do: seconds
  def calculate_delay(%__MODULE__{time: :immediate}), do: 0

  def calculate_delay(%__MODULE__{time: {:at, datetime}}) do
    DateTime.diff(datetime, AshDispatch.Clock.utc_now(), :second)
  end

  def calculate_delay(%__MODULE__{time: {:window, _window}}), do: 0

  def calculate_delay(_), do: 0

  @doc """
  Logs the `{:window, map}` deprecation once per boot.

  Business-hours windows were never implemented — a `{:window, …}` channel
  has always delivered immediately, silently. Rather than keep lying, the
  time spec is deprecated: it still delivers immediately (removing it would
  be a breaking change), but the first channel that uses it after boot says
  so in the log.

  Returns `:ok`.
  """
  @spec warn_window_deprecated() :: :ok
  def warn_window_deprecated do
    if :persistent_term.get(@window_deprecation_key, false) do
      :ok
    else
      :persistent_term.put(@window_deprecation_key, true)

      Logger.warning(
        "channel time {:window, ...} is deprecated and treated as immediate; " <>
          "use {:in, seconds} or {:at, %DateTime{}} instead"
      )

      :ok
    end
  end

  @doc false
  # Test hook: makes `warn_window_deprecated/0` warn again.
  @spec reset_window_deprecation_warning() :: :ok
  def reset_window_deprecation_warning do
    :persistent_term.erase(@window_deprecation_key)
    :ok
  end

  @doc """
  Checks if a channel matches given transport and/or audience filters.

  ## Examples

      iex> channel = %Channel{transport: :in_app, audience: :user}
      iex> Channel.matches?(channel, transport: :in_app)
      true

      iex> Channel.matches?(channel, transport: :email)
      false

      iex> Channel.matches?(channel, transport: :in_app, audience: :user)
      true
  """
  def matches?(%__MODULE__{} = channel, filters) do
    Enum.all?(filters, fn
      {:transport, transport} -> channel.transport == transport
      {:audience, audience} -> channel.audience == audience
      {:variant, variant} -> channel.variant == variant
      _ -> true
    end)
  end
end
