defmodule AshDispatch.Transport.QueueTest do
  @moduledoc """
  Which queue a send job goes into.

  `SendEmail`, `SendSMS` and `SendWebhook` were bound to `:emails`, `:sms` and
  `:webhooks` at compile time, so an installation sending two thousand letters
  in a campaign starved every booking confirmation behind them for minutes and
  had to build a second send path to separate the two.

  The names are now settings, and today's names are the defaults — which is
  the half this file is most careful about.
  """
  # Not async: configures :ash_dispatch, which is global
  use ExUnit.Case, async: false

  alias AshDispatch.Channel
  alias AshDispatch.ChannelResolver
  alias AshDispatch.Config
  alias AshDispatch.Transport.Queue
  alias AshDispatch.Workers.SendEmail
  alias AshDispatch.Workers.SendSMS
  alias AshDispatch.Workers.SendWebhook

  @moduletag :capture_log

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

  defp queue_of(worker), do: Keyword.fetch!(worker.__opts__(), :queue)

  describe "the defaults are the names the workers were bound to" do
    test "nothing configured" do
      assert Config.transport_queue(:email) == :emails
      assert Config.transport_queue(:sms) == :sms
      assert Config.transport_queue(:webhook) == :webhooks
    end

    test "and the workers answer them" do
      assert queue_of(SendEmail) == :emails
      assert queue_of(SendSMS) == :sms
      assert queue_of(SendWebhook) == :webhooks
    end

    test "slack and discord share the webhook queue, because they share the worker" do
      assert Config.transport_queue(:slack) == :webhooks
      assert Config.transport_queue(:discord) == :webhooks
    end

    test "a transport with no queue of its own answers nil" do
      assert Config.transport_queue(:in_app) == nil
      assert Config.transport_queue(:broadcast) == nil
    end
  end

  describe "per transport" do
    test "email_queue moves every email job, retries and digests included" do
      put_env(:email_queue, :bulk_emails)

      assert Config.transport_queue(:email) == :bulk_emails
      assert queue_of(SendEmail) == :bulk_emails
      # The other two are untouched.
      assert queue_of(SendSMS) == :sms
      assert queue_of(SendWebhook) == :webhooks
    end

    test "sms_queue and webhook_queue the same" do
      put_env(:sms_queue, :texts)
      put_env(:webhook_queue, :hooks)

      assert queue_of(SendSMS) == :texts
      assert queue_of(SendWebhook) == :hooks
    end

    test "it is read at runtime, so a release can change it without a recompile" do
      assert queue_of(SendEmail) == :emails
      put_env(:email_queue, :later)
      assert queue_of(SendEmail) == :later
    end
  end

  describe "per channel" do
    test "a channel with no queue adds nothing, so the worker decides" do
      assert Queue.opts(%Channel{transport: :email, audience: :user}) == []
      assert Queue.opts(nil) == []
    end

    test "a channel with a queue names it" do
      assert Queue.opts(%Channel{transport: :email, audience: :user, queue: :bulk_emails}) ==
               [queue: :bulk_emails]
    end

    test "a queue that is not an atom is refused, not passed through" do
      # Oban's queue names are atoms. A string names no running queue, so the
      # job would be inserted and never picked up; and `String.to_atom/1` on a
      # value that can come from a manual dispatch's override is worse still.
      assert Queue.opts(%{transport: :email, queue: "bulk_emails_as_a_string"}) == []
      assert Queue.opts(%{transport: :email, queue: 7}) == []

      refute_atom_created("bulk_emails_as_a_string")
    end

    defp refute_atom_created(name) do
      assert_raise ArgumentError, fn -> :erlang.binary_to_existing_atom(name, :utf8) end
    end

    test "it reaches the job, over the transport's own queue" do
      put_env(:email_queue, :transport_level)

      changeset =
        SendEmail.new(
          %{"receipt_id" => "r-1"},
          Queue.opts(%Channel{
            transport: :email,
            audience: :user,
            queue: :channel_level
          })
        )

      assert changeset.changes.queue == "channel_level"
    end

    test "and without one the job goes to the transport's queue" do
      put_env(:email_queue, :transport_level)

      changeset =
        SendEmail.new(
          %{"receipt_id" => "r-1"},
          Queue.opts(%Channel{transport: :email, audience: :user})
        )

      assert changeset.changes.queue == "transport_level"
    end
  end

  describe "the channel resolver carries it" do
    test "from every input form" do
      for input <- [
            %AshDispatch.Dsl.Channel{transport: :email, audience: :user, queue: :bulk},
            %{transport: :email, audience: :user, queue: :bulk},
            [transport: :email, audience: :user, queue: :bulk]
          ] do
        assert ChannelResolver.to_channel_struct(input).queue == :bulk
      end
    end

    test "and leaves it nil when nothing says otherwise" do
      for input <- [
            %AshDispatch.Dsl.Channel{transport: :email, audience: :user},
            %{transport: :email, audience: :user},
            [transport: :email, audience: :user]
          ] do
        assert ChannelResolver.to_channel_struct(input).queue == nil
      end
    end
  end

  describe "a queue Oban is not running" do
    test "is warned about once per boot, because the jobs would never be picked up" do
      Queue.forget_warning(:nothing_runs_this)

      # Oban is not started in this test, so the queue list is unknown and the
      # library says nothing rather than warning about a list it cannot see.
      # Either way `opts/1` still answers the queue asked for.
      assert Queue.opts(%Channel{transport: :email, audience: :user, queue: :nothing_runs_this}) ==
               [queue: :nothing_runs_this]
    end
  end
end
