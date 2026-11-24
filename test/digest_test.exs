defmodule AshDispatch.DigestTest do
  @moduledoc """
  Per-recipient digests, through the path production runs: the email
  transport batches, the flush sends — one email as itself, several as one
  digest — and every letter keeps its own receipt.

  Oban runs with the inline engine (as in `AshDispatch.Test.PreviewCase`):
  a job runs inside `Oban.insert/1`, so the flush job a batched email
  schedules runs at once, finds its window not due, and snoozes. The tests
  then flush with a `now:` past the window, which is what the scheduled job
  does when its time comes.
  """
  use ExUnit.Case, async: false

  alias AshDispatch.Channel
  alias AshDispatch.Context
  alias AshDispatch.Digest
  alias AshDispatch.EventResolver
  alias AshDispatch.Test.TransportReceipt
  alias AshDispatch.Transports.Email
  alias AshDispatch.Workers.FlushDigests

  @moduletag :capture_log

  @user_id "11111111-1111-1111-1111-111111111111"
  @other_user_id "22222222-2222-2222-2222-222222222222"

  defmodule EmailBackend do
    @moduledoc false
    def send_email(params) do
      send(self(), {:sent, params})
      {:ok, %{id: "provider-#{System.unique_integer([:positive])}"}}
    end
  end

  defmodule ModeChecker do
    @moduledoc false
    @behaviour AshDispatch.UserPreference

    @impl true
    def user_allows?(_user_id, _event_id, _transport, _opts), do: true

    @impl true
    def user_digest_mode(user_id, opts) do
      send(self(), {:asked, user_id, opts[:window]})
      Application.get_env(:ash_dispatch, :test_digest_mode, :default)
    end
  end

  defmodule NoBatchReceipt do
    @moduledoc false
    defstruct [:id, :user_id, transport: :email]
  end

  defmodule ItemEvent do
    @moduledoc false
    def digest_item(context, _channel) do
      %{title: "Comment on #{context.data.ticket}", url: "https://example.com/t/1"}
    end
  end

  @keys [
    :otp_app,
    :delivery_receipt_resource,
    :email_backend,
    :user_preference,
    :test_digest_mode,
    :digest_renderer,
    :digest_max_wait
  ]

  setup do
    saved = for key <- @keys, do: {key, Application.get_env(:ash_dispatch, key)}

    on_exit(fn ->
      for {key, value} <- saved do
        if is_nil(value),
          do: Application.delete_env(:ash_dispatch, key),
          else: Application.put_env(:ash_dispatch, key, value)
      end

      AshDispatch.Test.Ets.stop(TransportReceipt)
    end)

    for key <- @keys, do: Application.delete_env(:ash_dispatch, key)

    Application.put_env(:ash_dispatch, :otp_app, :ash_dispatch_test)
    Application.put_env(:ash_dispatch, :delivery_receipt_resource, TransportReceipt)
    Application.put_env(:ash_dispatch, :email_backend, EmailBackend)

    start_supervised!(
      {Oban,
       name: Oban,
       repo: AshDispatch.Test.Setup.Repo,
       engine: Oban.Engines.Inline,
       notifier: {Oban.Notifiers.Isolated, []},
       peer: {Oban.Peers.Isolated, [leader?: false]},
       plugins: [],
       queues: [],
       stager: false}
    )

    :ok
  end

  defp channel(time), do: %Channel{transport: :email, audience: :user, time: time}

  defp context(attrs \\ %{}) do
    struct(%Context{event_id: "ticket.commented", data: %{ticket: "T-1"}}, attrs)
  end

  defp receipt!(attrs \\ %{}) do
    TransportReceipt
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          event_id: "ticket.commented",
          audience: :user,
          transport: :email,
          user_id: @user_id,
          recipient: "customer@example.com",
          subject: "New comment",
          body_html: "<p>New comment</p>",
          body_text: "Hello Ada!\n\nBob wrote:   a  new comment.\n\nOpen the ticket.",
          content: %{from: "support@example.com", reply_to: "help@example.com"}
        },
        attrs
      )
    )
    |> Ash.create!(authorize?: false)
  end

  defp batch!(attrs \\ %{}, time \\ {:digest, {:quiet, 300}}) do
    {:ok, receipt} = Email.deliver(receipt!(attrs), context(), channel(time), [])
    receipt
  end

  defp reload(receipt), do: Ash.get!(TransportReceipt, receipt.id, authorize?: false)

  defp later(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)

  defp all_receipts, do: Ash.read!(TransportReceipt, authorize?: false)

  describe "windows" do
    test "a quiet window takes the default ceiling, never below its own quiet time" do
      Application.put_env(:ash_dispatch, :digest_max_wait, 1800)
      assert Digest.normalize({:quiet, 300}) == {:quiet, 300, 1800}
      assert Digest.normalize({:quiet, 3600}) == {:quiet, 3600, 3600}
      assert Digest.normalize({:quiet, 60, 120}) == {:quiet, 60, 120}
    end

    test "anything else is not a window" do
      for bad <- [{:quiet, 0}, {:quiet, 60, 30}, :hourly, {:in, 300}, nil] do
        assert Digest.normalize(bad) == nil
      end
    end

    test "keys round-trip" do
      for window <- [{:quiet, 300, 1800}, :daily, :weekly] do
        assert window |> Digest.key() |> Digest.parse_key() == window
      end

      assert Digest.parse_key("quiet:abc:1") == nil
      assert Digest.parse_key("hourly") == nil
    end

    test "a quiet window is due a quiet time after the newest, capped after the oldest" do
      t0 = ~U[2026-11-18 12:00:00Z]

      assert Digest.due_at({:quiet, 300, 1800}, [t0]) == ~U[2026-11-18 12:05:00Z]

      assert Digest.due_at({:quiet, 300, 1800}, [t0, DateTime.add(t0, 240)]) ==
               ~U[2026-11-18 12:09:00Z]

      # A steady trickle every four minutes would never go quiet; the ceiling
      # sends it half an hour after the first.
      trickle = for minute <- 0..40//4, do: DateTime.add(t0, minute * 60)
      assert Digest.due_at({:quiet, 300, 1800}, trickle) == ~U[2026-11-18 12:30:00Z]
    end

    test "daily and weekly windows go out at the next send time after the oldest" do
      # 2026-11-18 is a Wednesday. Defaults: 07:00 UTC, Monday.
      assert Digest.due_at(:daily, [~U[2026-11-18 06:59:00Z]]) == ~U[2026-11-18 07:00:00Z]
      assert Digest.due_at(:daily, [~U[2026-11-18 07:00:00Z]]) == ~U[2026-11-19 07:00:00Z]
      assert Digest.due_at(:weekly, [~U[2026-11-18 12:00:00Z]]) == ~U[2026-11-23 07:00:00Z]
      assert Digest.due_at(:weekly, [~U[2026-11-23 06:00:00Z]]) == ~U[2026-11-23 07:00:00Z]
      assert Digest.due_at(:weekly, [~U[2026-11-23 07:00:00Z]]) == ~U[2026-11-30 07:00:00Z]
    end

    test "an unknown digest window sends at once, and says so" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Digest.channel_window(channel({:digest, :hourly})) == nil
        end)

      assert log =~ "unknown digest window"
    end
  end

  describe "batching" do
    test "a digest channel holds the email instead of sending it" do
      receipt = batch!()

      assert receipt.status == :batched
      refute_received {:sent, _}

      digest = reload(receipt).content["digest"]
      assert digest["window"] == "quiet:300:1800"
      assert {:ok, _, _} = DateTime.from_iso8601(digest["batched_at"])

      # The item: the subject, and the first paragraph of the text body with
      # its whitespace folded.
      assert digest["item"]["title"] == "New comment"
      assert digest["item"]["summary"] == "Hello Ada!"
    end

    test "the content keeps one digest key, whatever spelling it arrived in" do
      receipt = batch!(%{content: %{from: "a@example.com", digest: %{"stale" => true}}})

      content = reload(receipt).content
      refute Map.has_key?(content, :digest)
      refute Map.has_key?(content["digest"], "stale")
    end

    test "a channel without a digest time is sent at once" do
      {:ok, _receipt} = Email.deliver(receipt!(), context(), channel({:in, 0}), [])

      assert_received {:sent, %{subject: "New comment"}}
    end

    test "a receipt resource without a :batch action sends at once, and says so" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Digest.window_for(
                   %NoBatchReceipt{id: "x", user_id: @user_id},
                   context(),
                   channel({:digest, {:quiet, 300}}),
                   []
                 ) == nil
        end)

      assert log =~ "has no :batch action"
    end

    test "a manual dispatch with a recipient override is never batched" do
      ctx = context(%{metadata: %{ash_dispatch_override: %{recipient_email: "qa@example.com"}}})

      {:ok, receipt} =
        Email.deliver(receipt!(), ctx, channel({:digest, {:quiet, 300}}), [])

      refute reload(receipt).status == :batched
      assert_received {:sent, _}
    end
  end

  describe "the person's say (user_digest_mode/2)" do
    setup do
      Application.put_env(:ash_dispatch, :user_preference, ModeChecker)
      :ok
    end

    test ":off sends each email at once" do
      Application.put_env(:ash_dispatch, :test_digest_mode, :off)

      receipt = batch!()

      refute receipt.status == :batched
      assert_received {:asked, @user_id, {:quiet, 300, 1800}}
      assert_received {:sent, %{subject: "New comment"}}
    end

    test "a window of their own replaces the channel's" do
      Application.put_env(:ash_dispatch, :test_digest_mode, :daily)

      receipt = batch!()

      assert reload(receipt).content["digest"]["window"] == "daily"
    end

    test ":default keeps the channel's window" do
      receipt = batch!()

      assert reload(receipt).content["digest"]["window"] == "quiet:300:1800"
    end

    test "an answer that is not a window keeps the channel's, and is logged" do
      Application.put_env(:ash_dispatch, :test_digest_mode, :hourly)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          receipt = batch!()
          assert reload(receipt).content["digest"]["window"] == "quiet:300:1800"
        end)

      assert log =~ "not a digest mode"
    end

    test "a channel that did not opt in is never delayed by a person's setting" do
      Application.put_env(:ash_dispatch, :test_digest_mode, :weekly)

      {:ok, _receipt} = Email.deliver(receipt!(), context(), channel({:in, 0}), [])

      refute_received {:asked, _, _}
      assert_received {:sent, _}
    end
  end

  describe "flushing" do
    test "before the window is due, nothing is sent and the job snoozes" do
      receipt = batch!()

      assert {:snooze, seconds} = Digest.flush(receipt.recipient, "quiet:300:1800")
      assert seconds in 290..300
      assert reload(receipt).status == :batched
      refute_received {:sent, _}
    end

    test "one waiting email is sent as itself" do
      receipt = batch!()

      assert :ok = Digest.flush(receipt.recipient, "quiet:300:1800", nil, now: later(301))

      assert_received {:sent, params}
      assert params.subject == "New comment"
      assert params.to == "customer@example.com"
      assert params.reply_to == "help@example.com"
      assert reload(receipt).status == :sent
    end

    test "several waiting emails become one digest with a receipt of its own" do
      first = batch!(%{subject: "Comment one", body_text: "First."})
      second = batch!(%{subject: "Comment two", body_text: "Second."})

      assert :ok = Digest.flush("customer@example.com", "quiet:300:1800", nil, now: later(301))

      assert_received {:sent, params}
      refute_received {:sent, _}

      assert params.subject == "2 updates"
      assert params.to == "customer@example.com"
      assert params.reply_to == "help@example.com"
      assert params.html_body =~ "Comment one"
      assert params.html_body =~ "Comment two"
      assert params.text_body =~ "- Comment one\n  First."

      [digest] = Enum.filter(all_receipts(), &(&1.event_id == "ash_dispatch.digest"))
      assert digest.status == :sent
      assert digest.user_id == @user_id
      assert Enum.sort(digest.content["digest"]["entries"]) == Enum.sort([first.id, second.id])

      for entry <- [first, second] do
        entry = reload(entry)
        assert entry.status == :digested
        assert entry.content["digest"]["receipt_id"] == digest.id
      end
    end

    test "each recipient gets their own digest" do
      batch!()
      batch!(%{user_id: @other_user_id, recipient: "other@example.com"})

      for address <- ["customer@example.com", "other@example.com"] do
        assert :ok = Digest.flush(address, "quiet:300:1800", nil, now: later(301))
      end

      assert_received {:sent, %{to: "customer@example.com", subject: "New comment"}}
      assert_received {:sent, %{to: "other@example.com", subject: "New comment"}}
    end

    test "different windows for one person are separate groups" do
      batch!(%{subject: "Quiet"})
      batch!(%{subject: "Daily"}, {:digest, :daily})

      assert :ok = Digest.flush("customer@example.com", "quiet:300:1800", nil, now: later(301))

      assert_received {:sent, %{subject: "Quiet"}}
      refute_received {:sent, _}
    end

    test "force: true sends a window that is not due" do
      batch!()

      assert :ok = Digest.flush("customer@example.com", "quiet:300:1800", nil, force: true)
      assert_received {:sent, _}
    end

    test "nothing waiting is :ok" do
      assert :ok = Digest.flush("nobody@example.com", "quiet:300:1800")
    end

    test "the sweep sends every group that is due and leaves the rest" do
      batch!(%{subject: "Soon"})
      batch!(%{subject: "Tomorrow", recipient: "late@example.com"}, {:digest, :daily})

      assert :ok = Digest.sweep(nil, now: later(301))

      assert_received {:sent, %{subject: "Soon"}}
      refute_received {:sent, _}

      [late] = Enum.filter(all_receipts(), &(&1.recipient == "late@example.com"))
      assert late.status == :batched
    end
  end

  describe "the flush job" do
    test "is unique per recipient, window and tenant, and moves rather than duplicates" do
      due = ~U[2026-11-18 12:05:00Z]
      changeset = FlushDigests.job("a@example.com", "quiet:300:1800", "tenant_a", due)

      assert changeset.changes.args == %{
               "recipient" => "a@example.com",
               "window" => "quiet:300:1800",
               "tenant" => "tenant_a"
             }

      assert DateTime.compare(changeset.changes.scheduled_at, due) == :eq
      assert changeset.changes.queue == "emails"
      assert changeset.changes.unique.keys == [:recipient, :window, :tenant]
      assert changeset.changes.replace == [scheduled: [:scheduled_at]]
    end

    test "leaves the tenant out for a host without tenants" do
      changeset = FlushDigests.job("a@example.com", "daily", nil, ~U[2026-11-19 07:00:00Z])
      refute Map.has_key?(changeset.changes.args, "tenant")
    end
  end

  describe "items and rendering" do
    test "an event's digest_item/2 is read, and a non-map counts as none" do
      assert EventResolver.digest_item(ItemEvent, context(), channel(nil)) == %{
               title: "Comment on T-1",
               url: "https://example.com/t/1"
             }

      assert EventResolver.digest_item(String, context(), channel(nil)) == %{}
    end

    test "the default renderer escapes what the events said" do
      letter =
        AshDispatch.DigestRenderer.Default.render(
          [
            %{
              "title" => "<b>Bold</b> & co",
              "summary" => nil,
              "url" => "https://x.test/?a=1&b=2"
            },
            %{"title" => "Plain", "summary" => "Said \"hi\"", "url" => nil}
          ],
          %{recipient: "a@example.com", user_id: nil, locale: nil, count: 2}
        )

      assert letter.subject == "2 updates"
      assert letter.html_body =~ "&lt;b&gt;Bold&lt;/b&gt; &amp; co"
      assert letter.html_body =~ ~s(href="https://x.test/?a=1&amp;b=2")
      assert letter.html_body =~ "Said &quot;hi&quot;"
      refute letter.html_body =~ "<b>Bold</b>"
      assert letter.text_body =~ "- <b>Bold</b> & co\n  https://x.test/?a=1&b=2"
    end

    test "a host renderer decides the letter" do
      defmodule Renderer do
        @moduledoc false
        @behaviour AshDispatch.DigestRenderer

        @impl true
        def render(items, info) do
          %{
            subject: "Dina #{info.count} uppdateringar",
            html_body: Enum.map_join(items, &"<p>#{&1["title"]}</p>"),
            text_body: Enum.map_join(items, "\n", & &1["title"]),
            from: {"Projekt", "projekt@example.com"}
          }
        end
      end

      Application.put_env(:ash_dispatch, :digest_renderer, Renderer)

      batch!(%{subject: "A"})
      batch!(%{subject: "B"})

      assert :ok = Digest.flush("customer@example.com", "quiet:300:1800", nil, force: true)

      assert_received {:sent, params}
      assert params.subject == "Dina 2 uppdateringar"
      assert params.from == {"Projekt", "projekt@example.com"}
      assert params.text_body == "A\nB"
    end
  end
end
