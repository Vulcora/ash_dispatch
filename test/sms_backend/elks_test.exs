defmodule AshDispatch.SMSBackend.ElksTest do
  @moduledoc """
  46elks-backenden mot en stubbad HTTP-klient.

  Det som prövas är felkartan, inte lyckofallet: vilka svar som är värda ett
  omförsök och vilka som aldrig blir bättre. Ett feltypat telefonnummer eller
  ett fel lösenord ska inte bränna fem omförsök över 75 minuter innan någon
  får veta.
  """
  use ExUnit.Case, async: false

  alias AshDispatch.SMSBackend.Elks
  alias AshDispatch.Test.TransportReceipt

  setup do
    tidigare = Application.get_env(:ash_dispatch, Elks)

    Application.put_env(:ash_dispatch, Elks,
      username: "u1",
      password: "p1",
      from: "Korschema"
    )

    on_exit(fn ->
      if tidigare,
        do: Application.put_env(:ash_dispatch, Elks, tidigare),
        else: Application.delete_env(:ash_dispatch, Elks)

      Application.delete_env(:ash_dispatch, :elks_test_svar)
    end)

    :ok
  end

  defp kvitto!(attrs \\ %{}) do
    TransportReceipt
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          event_id: "schedule.notified",
          transport: :sms,
          recipient: "0701234567",
          content: %{message: "Körschema V39"}
        },
        attrs
      )
    )
    |> Ash.create!(authorize?: false)
  end

  # Backenden skickar :req_options rakt in i Req.post/2, så stubben går in
  # via konfigurationen utan att backenden känner till testet.
  defp stubba(svar) do
    Application.put_env(
      :ash_dispatch,
      Elks,
      Keyword.put(Application.get_env(:ash_dispatch, Elks), :req_options, plug: svar)
    )
  end

  describe "lyckad sändning" do
    test "200 markerar :sent och sparar leverantörens id" do
      stubba(fn conn ->
        Req.Test.json(conn, %{"id" => "s1a2b3", "status" => "created"})
      end)

      assert {:ok, uppdaterat} = Elks.deliver(kvitto!(), nil, nil, %{})
      assert uppdaterat.status == :sent
      assert uppdaterat.provider_id == "s1a2b3"
    end

    test "numret normaliseras innan det skickas" do
      test_pid = self()

      stubba(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:skickat, URI.decode_query(body)})
        Req.Test.json(conn, %{"id" => "s1"})
      end)

      Elks.deliver(kvitto!(%{recipient: "070-123 45 67"}), nil, nil, %{})

      assert_received {:skickat, form}
      assert form["to"] == "+46701234567"
      assert form["from"] == "Korschema"
      assert form["message"] == "Körschema V39"
    end

    test "dryrun skickar flaggan och markerar ändå :sent" do
      test_pid = self()

      Application.put_env(
        :ash_dispatch,
        Elks,
        Keyword.put(Application.get_env(:ash_dispatch, Elks), :dryrun, true)
      )

      stubba(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:skickat, URI.decode_query(body)})
        Req.Test.json(conn, %{"id" => "s9"})
      end)

      assert {:ok, uppdaterat} = Elks.deliver(kvitto!(), nil, nil, %{})

      assert_received {:skickat, form}
      assert form["dryrun"] == "yes"
      assert uppdaterat.status == :sent
      assert uppdaterat.provider_id == "dryrun:s9"
    end
  end

  describe "fel som aldrig blir bättre" do
    for status <- [400, 401, 403] do
      test "#{status} blir :failed_permanent, inte fem omförsök" do
        stubba(fn conn ->
          conn
          |> Plug.Conn.put_status(unquote(status))
          |> Req.Test.json(%{"message" => "nope"})
        end)

        assert {:ok, uppdaterat} = Elks.deliver(kvitto!(), nil, nil, %{})
        assert uppdaterat.status == :failed_permanent
        assert uppdaterat.error_message =~ "#{unquote(status)}"
      end
    end

    test "ett oanvändbart telefonnummer når aldrig leverantören" do
      stubba(fn _conn -> raise "backenden skulle inte ha ringt" end)

      assert {:ok, uppdaterat} = Elks.deliver(kvitto!(%{recipient: "123"}), nil, nil, %{})
      assert uppdaterat.status == :failed_permanent
    end

    test "ett kvitto utan text når aldrig leverantören" do
      stubba(fn _conn -> raise "backenden skulle inte ha ringt" end)

      assert {:ok, uppdaterat} = Elks.deliver(kvitto!(%{content: %{}}), nil, nil, %{})
      assert uppdaterat.status == :failed_permanent
      assert uppdaterat.error_message =~ "sms-text"
    end
  end

  describe "fel som är värda ett omförsök" do
    test "500 blir :failed" do
      stubba(fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "oops"})
      end)

      assert {:ok, uppdaterat} = Elks.deliver(kvitto!(), nil, nil, %{})
      assert uppdaterat.status == :failed
    end

    test "nätverksfel blir :failed" do
      stubba(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:ok, uppdaterat} = Elks.deliver(kvitto!(), nil, nil, %{})
      assert uppdaterat.status == :failed
    end
  end

  describe "texten läses oavsett nyckeltyp" do
    test "atomnyckel (färsk struct ur dispatchern)" do
      stubba(fn conn -> Req.Test.json(conn, %{"id" => "s1"}) end)
      assert {:ok, r} = Elks.deliver(kvitto!(%{content: %{message: "hej"}}), nil, nil, %{})
      assert r.status == :sent
    end

    test "strängnyckel (efter Postgres-rundresa)" do
      stubba(fn conn -> Req.Test.json(conn, %{"id" => "s1"}) end)
      assert {:ok, r} = Elks.deliver(kvitto!(%{content: %{"message" => "hej"}}), nil, nil, %{})
      assert r.status == :sent
    end
  end

  describe "utan konfiguration" do
    test "saknade uppgifter markerar :failed, inte en krasch" do
      Application.put_env(:ash_dispatch, Elks, username: nil, password: nil)

      assert {:ok, uppdaterat} = Elks.deliver(kvitto!(), nil, nil, %{})
      assert uppdaterat.status == :failed
      assert uppdaterat.error_message =~ "konfigurerad"
    end
  end
end
