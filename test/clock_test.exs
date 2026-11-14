defmodule AshDispatch.ClockTest do
  @moduledoc """
  A clock the host can supply (#50 point 3, BACKLOG 13).

  Two things have to be true at once. The default must be exactly what every
  release before 0.9.4-rc.4 did — `DateTime.utc_now/0`, no column touched, no
  behaviour changed for a host that configures nothing — and a configured
  clock must be what is actually *stored*, and what the retry, scrub and
  stranded cut-offs are actually compared against. A clock nothing persisted
  reads would be worse than no clock.
  """
  # Not async: every test here sets `config :ash_dispatch, :clock`, which the
  # whole library reads out of the real application environment.
  use ExUnit.Case, async: false

  alias AshDispatch.Clock

  @frozen ~U[2026-03-01 12:00:00.000000Z]

  defmodule Frozen do
    @moduledoc false
    # One instant, settable. An Agent rather than a module attribute so a test
    # can travel without recompiling.
    use Agent

    def start_link(at), do: Agent.start_link(fn -> at end, name: __MODULE__)
    def utc_now, do: Agent.get(__MODULE__, & &1)
    def travel(to), do: Agent.update(__MODULE__, fn _ -> to end)
  end

  defp freeze(at \\ @frozen) do
    start_supervised!({Frozen, at})
    configure({Frozen, :utc_now, []})
  end

  defp configure(clock), do: put_env(:clock, clock)

  defp put_env(key, value) do
    previous = Application.fetch_env(:ash_dispatch, key)
    Application.put_env(:ash_dispatch, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:ash_dispatch, key, old)
        :error -> Application.delete_env(:ash_dispatch, key)
      end
    end)
  end

  describe "the default" do
    test "is DateTime.utc_now/0" do
      before = DateTime.utc_now()
      now = Clock.utc_now()

      assert %DateTime{} = now
      assert DateTime.compare(now, before) in [:gt, :eq]
      assert DateTime.compare(now, DateTime.utc_now()) in [:lt, :eq]
    end
  end

  describe "the spellings it accepts" do
    test "{module, function, args}" do
      freeze()
      assert Clock.utc_now() == @frozen
    end

    test "a bare module means its utc_now/0" do
      start_supervised!({Frozen, @frozen})
      configure(Frozen)

      assert Clock.utc_now() == @frozen
    end

    test "a 0-arity function" do
      configure(fn -> @frozen end)
      assert Clock.utc_now() == @frozen
    end

    test "clock: DateTime is the default, spelled out" do
      configure(DateTime)
      assert %DateTime{} = Clock.utc_now()
    end

    test "a value it does not understand is named, not guessed at" do
      configure("12:00")

      assert_raise ArgumentError, ~r/clock: "12:00"` is not a value/, fn -> Clock.utc_now() end
    end

    test "a clock that does not return a DateTime is named too" do
      configure(fn -> ~N[2026-03-01 12:00:00] end)

      assert_raise ArgumentError, ~r/returned ~N\[2026-03-01 12:00:00\], not a DateTime/, fn ->
        Clock.utc_now()
      end
    end
  end

  describe "AshDispatch.Context" do
    test ":now comes from the clock when the caller does not pass one" do
      freeze()

      context = AshDispatch.Context.new(event_id: "orders.created", data: %{})

      assert context.now == @frozen
    end

    test "a :now the caller passed still wins" do
      freeze()
      chosen = ~U[2020-01-01 00:00:00.000000Z]

      context = AshDispatch.Context.new(event_id: "orders.created", data: %{}, now: chosen)

      assert context.now == chosen
    end

    test "the broadcast payload's timestamp is the configured clock" do
      freeze()
      put_env(:pubsub_module, AshDispatch.Test.InboxPubSub)
      put_env(:capture_pid, self())

      # `id: nil` keeps the transport off the receipt: there is nothing to
      # mark sent, and this test is about the payload.
      receipt = %{id: nil, user_id: Ash.UUID.generate(), content: %{}}
      context = AshDispatch.Context.new(event_id: "orders.created", data: %{})
      channel = %AshDispatch.Channel{transport: :broadcast, audience: :user}

      assert {:ok, _receipt} =
               AshDispatch.Transports.Broadcast.deliver(receipt, context, channel, [])

      assert_received {:broadcast, _topic, _event, payload}
      assert payload.timestamp == DateTime.to_iso8601(@frozen)
    end
  end

  describe "the cut-offs a cron pass compares against" do
    test "the retry cut-off is the configured clock, minus the delay" do
      freeze()

      assert AshDispatch.Workers.RetryFailedDeliveries.cutoff(5) ==
               DateTime.add(@frozen, -5 * 60, :second)
    end

    test "the scrub cut-offs are the configured clock, minus the windows" do
      freeze()

      {cutoff, stranded} = AshDispatch.Workers.ScrubSensitiveContent.cutoffs(Clock.utc_now())

      assert DateTime.compare(cutoff, @frozen) == :lt
      assert DateTime.compare(stranded, @frozen) == :lt
      # The cap is never shorter than the window.
      assert DateTime.compare(stranded, cutoff) in [:lt, :eq]
    end

    test "a receipt's staleness is measured by the configured clock" do
      freeze()

      # Written "one minute ago" on the frozen clock: inside the default
      # 15-minute grace, so nothing is done to it...
      assert AshDispatch.Workers.Stranded.action(DateTime.add(@frozen, -60, :second)) == :leave

      # ...and the same row is stranded once the clock moves on, with no row
      # touched and no sleeping.
      Frozen.travel(DateTime.add(@frozen, 3600, :second))
      assert AshDispatch.Workers.Stranded.action(DateTime.add(@frozen, -60, :second)) == :rescue
    end
  end

  describe "what is NOT on the clock, on purpose" do
    # Ash's `timestamps` macro defaults both to the capture
    # `&DateTime.utc_now/0`, and that exact value is what ash_postgres matches
    # on to write `DEFAULT (now() AT TIME ZONE 'utc')`. Moving it changes what
    # the next `mix ash.codegen` emits in every host, so it is 0.10.0. This
    # test is the guard: it fails if someone "finishes the job".
    test "inserted_at and updated_at still carry Ash's own capture" do
      for resource <- [
            AshDispatch.Test.SdkBases.Notification,
            AshDispatch.Test.SdkBases.Preference,
            AshDispatch.Test.SdkBases.Receipt
          ],
          name <- [:inserted_at, :updated_at] do
        attribute = Ash.Resource.Info.attribute(resource, name)

        assert attribute.default == (&DateTime.utc_now/0),
               "#{inspect(resource)}.#{name} must keep Ash's &DateTime.utc_now/0: " <>
                 "ash_postgres derives the column DEFAULT from that exact capture, " <>
                 "and a patch release may not require a migration (BACKLOG 13)"
      end
    end

    # The other direction: `occurred_at` could move because its default was
    # already an `{m, f, a}` tuple, which ash_postgres maps to no column
    # default at all. It must stay a tuple for the same reason.
    test "occurred_at is on the clock, and still as an {m, f, a}" do
      attribute =
        Ash.Resource.Info.attribute(AshDispatch.Test.SdkBases.Notification, :occurred_at)

      assert attribute.default == {AshDispatch.Clock, :utc_now, []}
    end

    test "the Resend webhook's timestamp tolerance stays on the wall clock" do
      freeze(~U[2001-01-01 00:00:00.000000Z])

      # A signature stamped now is fresh, although the configured clock says
      # it is 2001: a replay check must not be freezable.
      ts = System.system_time(:second)
      secret = "whsec_" <> Base.encode64("sekrit")
      body = ~s({"type":"email.sent"})
      id = "msg_1"

      signature = resend_signature(secret, id, ts, body)

      headers = %{
        "svix-id" => id,
        "svix-timestamp" => to_string(ts),
        "svix-signature" => signature
      }

      assert :ok = AshDispatch.WebhookHandlers.Resend.verify(body, headers, secret)
    end
  end

  defp resend_signature(secret, id, ts, body) do
    "whsec_" <> b64 = secret
    {:ok, key} = Base.decode64(b64)

    mac =
      :crypto.mac(:hmac, :sha256, key, "#{id}.#{ts}.#{body}")
      |> Base.encode64()

    "v1,#{mac}"
  end
end
