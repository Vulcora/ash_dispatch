defmodule AshDispatch.Clock do
  @moduledoc """
  The one place this library asks what time it is.

  A host that routes time through a module of its own — frozen in tests,
  travelled in a simulation — did not control any timestamp this library wrote
  before 0.9.4-rc.4. `occurred_at`, `sent_at`, `read_at`, `seen_at`,
  `archived_at` and `last_retry_at` were `DateTime.utc_now/0` called inline,
  and so were the cut-offs the retry and scrub passes compare against. The
  first per-tenant host asked for exactly this half (#50, BACKLOG 13).

      config :ash_dispatch, clock: {MyApp.Clock, :utc_now, []}

  Unset, it is `DateTime.utc_now/0`, which is byte-for-byte what every release
  before this one did. Two shorter spellings are accepted:

      config :ash_dispatch, clock: MyApp.Clock        # MyApp.utc_now/0
      config :ash_dispatch, clock: &MyApp.now/0       # any 0-arity function

  ## What goes through it

  Everything this library writes **from Elixir** into a stored column, and
  every cut-off it compares a stored column against:

  | Written or compared | Where |
  |---|---|
  | `occurred_at` | `Notification.Base`'s `:create` |
  | `read_at`, `seen_at`, `archived_at` | `Notification.Base`'s mark/archive actions |
  | `sent_at`, `last_retry_at` | `DeliveryReceipt.Base` |
  | the retry cut-off | `AshDispatch.Workers.RetryFailedDeliveries` |
  | the scrub and stranded cut-offs | `AshDispatch.Workers.ScrubSensitiveContent`, `AshDispatch.Workers.Stranded` |
  | `AshDispatch.Context`'s `:now` | every dispatch, and the broadcast payload's timestamp |
  | a webhook envelope's `sent_at`, a Resend event's `webhook_received_at` | `AshDispatch.Transports.Webhook`, `AshDispatch.WebhookHandlers.Resend` |

  ## What does not, and why

  - **`inserted_at` and `updated_at`.** They come from Ash's `timestamps`
    macro, whose default is the literal capture `&DateTime.utc_now/0` — which
    is the exact value ash_postgres matches on to write
    `DEFAULT (now() AT TIME ZONE 'utc')` into the migration. Replacing it
    changes what the next `mix ash.codegen` emits for every host, so it is
    0.10.0 work. BACKLOG 13 keeps it, with the reason.
  - **The Resend webhook's timestamp tolerance**
    (`AshDispatch.WebhookHandlers.Resend`, `check_freshness/2`). That compares
    our wall clock against the *sender's*, to reject a replayed signature. A
    frozen or travelled clock would make stale signatures pass or fresh ones
    fail, so it stays on `System.system_time/1`. It already takes a `:now`
    option for tests.
  - **"Generated at" banners** in `mix ash_dispatch.gen` and
    `mix ash_dispatch.gen.previews`. Build-time text in a generated file;
    nothing stores or compares it.

  Freezing time in a test is in the *Previews and testing* guide.
  """

  @default {DateTime, :utc_now, []}

  @doc """
  Now, according to the configured clock.

  `DateTime.utc_now/0` unless `config :ash_dispatch, :clock` says otherwise.
  """
  @spec utc_now() :: DateTime.t()
  def utc_now do
    clock = configured()

    case call(clock) do
      %DateTime{} = now ->
        now

      other ->
        raise ArgumentError, bad_result(clock, other)
    end
  end

  defp call({module, function, args}), do: apply(module, function, args)
  defp call(fun) when is_function(fun, 0), do: fun.()

  defp configured do
    case Application.get_env(:ash_dispatch, :clock) do
      nil ->
        @default

      {module, function, args} when is_atom(module) and is_atom(function) and is_list(args) ->
        {module, function, args}

      # A bare module means its `utc_now/0`, which is what `DateTime` itself
      # answers to — so `clock: DateTime` is the default, spelled out.
      module when is_atom(module) and not is_boolean(module) ->
        {module, :utc_now, []}

      fun when is_function(fun, 0) ->
        fun

      other ->
        raise ArgumentError, bad_clock(other)
    end
  end

  defp bad_clock(other) do
    """
    AshDispatch: `config :ash_dispatch, clock: #{inspect(other)}` is not a value this library understands.

    Expected one of:

      clock: {MyApp.Clock, :utc_now, []}   # module, function, arguments
      clock: MyApp.Clock                   # the same as {MyApp.Clock, :utc_now, []}
      clock: &MyApp.now/0                  # any 0-arity function

    Leave the key out for `DateTime.utc_now/0`, which is what every release
    before 0.9.4-rc.4 did and what a host that sets nothing still gets.
    """
  end

  defp bad_result(clock, other) do
    """
    AshDispatch: the configured clock returned #{inspect(other)}, not a DateTime.

        config :ash_dispatch, clock: #{inspect(clock)}

    It is called with no arguments and must return a `DateTime` in UTC: the
    values it produces are written into `utc_datetime_usec` columns and
    compared against them. `DateTime.utc_now/0` is the shape to match.
    """
  end
end
