defmodule AshDispatch.Transports.PushTest do
  @moduledoc """
  The Web Push transport. Same shape as SMS: ash_dispatch owns the routing
  and the receipt, the consumer owns the protocol (VAPID, RFC 8291 encryption,
  per-endpoint-POST).
  """

  use ExUnit.Case, async: false

  alias AshDispatch.Transports.Push

  setup do
    previous = Application.get_env(:ash_dispatch, :push_backend)

    on_exit(fn ->
      if previous do
        Application.put_env(:ash_dispatch, :push_backend, previous)
      else
        Application.delete_env(:ash_dispatch, :push_backend)
      end
    end)

    Application.delete_env(:ash_dispatch, :push_backend)
    :ok
  end

  describe "transport-metadata" do
    test "registers as :push and creates receipts" do
      assert Push.transport_atom() == :push
      assert Push.skip_receipt?() == false
    end

    test "is reachable through the registry" do
      assert {:ok, Push} = AshDispatch.Transport.Registry.module_for(:push)
    end
  end

  describe "with no backend configured" do
    test "does not delegate — an app may declare :push channels before a backend exists" do
      # We verify the contract without touching the database: `deliver/4` must
      # NOT try to call a backend when none is configured.
      assert Application.get_env(:ash_dispatch, :push_backend) == nil
      assert AshDispatch.Config.push_backend() == nil
    end
  end

  describe "with a backend configured" do
    defmodule EchoBackend do
      @behaviour AshDispatch.PushBackend

      @impl true
      def deliver(receipt, _context, _channel, _event_config) do
        send(self(), {:push_delivered, receipt})
        {:ok, Map.put(receipt, :status, :sent)}
      end
    end

    # The channel is a real %Channel{} as of 0.7.0: push now asks for consent,
    # and the consent gate reads `channel.audience`. An empty map worked while
    # nobody read from it — and `:admin` is chosen deliberately, an ungated
    # audience, so this stays a test about delegation.
    @ungated %AshDispatch.Channel{transport: :push, audience: :admin}

    test "delegates deliver/4 to the backend module" do
      Application.put_env(:ash_dispatch, :push_backend, EchoBackend)

      receipt = %{id: "r-1", user_id: "u-1", content: %{title: "Meeting in 15 minutes"}}

      assert {:ok, updated} = Push.deliver(receipt, %{}, @ungated, %{})
      assert updated.status == :sent
      assert_received {:push_delivered, ^receipt}
    end

    test "backend errors bubble up to the dispatcher instead of being swallowed" do
      defmodule BrokenBackend do
        @behaviour AshDispatch.PushBackend

        @impl true
        def deliver(_receipt, _context, _channel, _event_config) do
          {:error, :push_service_unavailable}
        end
      end

      Application.put_env(:ash_dispatch, :push_backend, BrokenBackend)

      assert {:error, :push_service_unavailable} =
               Push.deliver(%{id: "r-2"}, %{}, @ungated, %{})
    end
  end

  describe "Config.push_backend/0" do
    test "reads :ash_dispatch, :push_backend" do
      Application.put_env(:ash_dispatch, :push_backend, EchoBackend)
      assert AshDispatch.Config.push_backend() == EchoBackend
    end

    test "is nil when nothing is configured" do
      assert AshDispatch.Config.push_backend() == nil
    end
  end

  describe "the dispatcher's content builder" do
    # The regression 0.6.0 introduced: `build_inline_content/4` had a
    # `case channel.transport` WITHOUT a catch-all, so a newly registered
    # transport crashed THE WHOLE dispatch with CaseClauseError — not just
    # its own channel. That contradicts what `AshDispatch.Transport` promises:
    # "one new file + one entry in the registry".
    #
    # Dispatch has no lightweight test harness here (it is tested from the
    # consumer applications), and exposing a private function purely for tests
    # would be worse than the problem. The guarantee is therefore structural:
    # the source must have a catch-all.
    @dispatcher File.read!("lib/dispatcher.ex")

    test "build_inline_content has a catch-all for unknown transports" do
      [_, body] = String.split(@dispatcher, "defp build_inline_content(", parts: 2)
      [body, _] = String.split(body, "\n  defp ", parts: 2)

      assert body =~ ~r/^\s+_ ->/m,
             """
             `build_inline_content/4` has no catch-all in its
             transport case. Without it the whole dispatch crashes as soon as
             someone registers a transport without adding a branch — contrary
             to what AshDispatch.Transport promises.
             """
    end

    test "push has a content branch of its own" do
      [_, body] = String.split(@dispatcher, "defp build_inline_content(", parts: 2)
      [body, _] = String.split(body, "\n  defp ", parts: 2)

      assert body =~ ~r/^\s+:push ->/m
      assert body =~ ~r/:action_url/
    end
  end
end
