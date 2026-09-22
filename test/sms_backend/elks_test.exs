defmodule AshDispatch.SMSBackend.ElksTest do
  @moduledoc """
  The 46elks backend against a stubbed HTTP client.

  What is under test is the failure map, not the happy path: which responses
  are worth retrying and which will never improve. A malformed phone number or
  a wrong password should not burn five retries over 75 minutes before anyone
  is told.
  """
  use ExUnit.Case, async: false

  alias AshDispatch.SMSBackend.Elks
  alias AshDispatch.Test.TransportReceipt

  setup do
    previous = Application.get_env(:ash_dispatch, Elks)

    Application.put_env(:ash_dispatch, Elks,
      username: "u1",
      password: "p1",
      from: "Notify"
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ash_dispatch, Elks, previous),
        else: Application.delete_env(:ash_dispatch, Elks)

      Application.delete_env(:ash_dispatch, :elks_test_response)
    end)

    :ok
  end

  defp receipt!(attrs \\ %{}) do
    TransportReceipt
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          event_id: "schedule.notified",
          transport: :sms,
          recipient: "0701234567",
          content: %{message: "Your order is on its way"}
        },
        attrs
      )
    )
    |> Ash.create!(authorize?: false)
  end

  # The backend passes :req_options straight into Req.post/2, so the stub goes
  # in through configuration without the backend knowing about the test.
  defp stub(plug) do
    Application.put_env(
      :ash_dispatch,
      Elks,
      Keyword.put(Application.get_env(:ash_dispatch, Elks), :req_options, plug: plug)
    )
  end

  describe "a successful send" do
    test "200 marks :sent and stores the provider id" do
      stub(fn conn ->
        Req.Test.json(conn, %{"id" => "s1a2b3", "status" => "created"})
      end)

      assert {:ok, updated} = Elks.deliver(receipt!(), nil, nil, %{})
      assert updated.status == :sent
      assert updated.provider_id == "s1a2b3"
    end

    test "the number is normalised before it is sent" do
      test_pid = self()

      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:posted, URI.decode_query(body)})
        Req.Test.json(conn, %{"id" => "s1"})
      end)

      Elks.deliver(receipt!(%{recipient: "070-123 45 67"}), nil, nil, %{})

      assert_received {:posted, form}
      assert form["to"] == "+46701234567"
      assert form["from"] == "Notify"
      assert form["message"] == "Your order is on its way"
    end

    test "dryrun sends the flag and still marks :sent" do
      test_pid = self()

      Application.put_env(
        :ash_dispatch,
        Elks,
        Keyword.put(Application.get_env(:ash_dispatch, Elks), :dryrun, true)
      )

      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:posted, URI.decode_query(body)})
        Req.Test.json(conn, %{"id" => "s9"})
      end)

      assert {:ok, updated} = Elks.deliver(receipt!(), nil, nil, %{})

      assert_received {:posted, form}
      assert form["dryrun"] == "yes"
      assert updated.status == :sent
      assert updated.provider_id == "dryrun:s9"
    end
  end

  describe "failures that never improve" do
    for status <- [400, 401, 403] do
      test "#{status} becomes :failed_permanent, not five retries" do
        stub(fn conn ->
          conn
          |> Plug.Conn.put_status(unquote(status))
          |> Req.Test.json(%{"message" => "nope"})
        end)

        assert {:ok, updated} = Elks.deliver(receipt!(), nil, nil, %{})
        assert updated.status == :failed_permanent
        assert updated.error_message =~ "#{unquote(status)}"
      end
    end

    test "an unusable phone number never reaches the provider" do
      stub(fn _conn -> raise "the backend should not have been called" end)

      assert {:ok, updated} = Elks.deliver(receipt!(%{recipient: "123"}), nil, nil, %{})
      assert updated.status == :failed_permanent
    end

    test "a receipt with no body never reaches the provider" do
      stub(fn _conn -> raise "the backend should not have been called" end)

      assert {:ok, updated} = Elks.deliver(receipt!(%{content: %{}}), nil, nil, %{})
      assert updated.status == :failed_permanent
      assert updated.error_message =~ "no sms body"
    end
  end

  describe "failures worth retrying" do
    test "500 becomes :failed" do
      stub(fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "oops"})
      end)

      assert {:ok, updated} = Elks.deliver(receipt!(), nil, nil, %{})
      assert updated.status == :failed
    end

    test "a network error becomes :failed" do
      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:ok, updated} = Elks.deliver(receipt!(), nil, nil, %{})
      assert updated.status == :failed
    end
  end

  describe "the body is read whichever key type it carries" do
    test "atom key (a fresh struct from the dispatcher)" do
      stub(fn conn -> Req.Test.json(conn, %{"id" => "s1"}) end)
      assert {:ok, r} = Elks.deliver(receipt!(%{content: %{message: "hi"}}), nil, nil, %{})
      assert r.status == :sent
    end

    test "string key (after a Postgres round trip)" do
      stub(fn conn -> Req.Test.json(conn, %{"id" => "s1"}) end)
      assert {:ok, r} = Elks.deliver(receipt!(%{content: %{"message" => "hi"}}), nil, nil, %{})
      assert r.status == :sent
    end
  end

  describe "with no configuration" do
    test "missing credentials mark :failed, not a crash" do
      Application.put_env(:ash_dispatch, Elks, username: nil, password: nil)

      assert {:ok, updated} = Elks.deliver(receipt!(), nil, nil, %{})
      assert updated.status == :failed
      assert updated.error_message =~ "not configured"
    end
  end
end
