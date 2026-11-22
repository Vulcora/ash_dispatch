defmodule AshDispatch.Plugs.RawBodyReaderTest do
  @moduledoc """
  The raw body a signature can actually be checked against.

  A JSON parser consumes the body and hands back a map; re-encoding that map
  gives different bytes, so the signature never matches. Four hosts wrote the
  same twelve lines before wiring `verify/4` in.
  """
  use ExUnit.Case, async: true

  import Plug.Test

  alias AshDispatch.Plugs.RawBodyReader

  @body ~s({"type":"email.opened","data":{"email_id":"prov-1"}})

  defp request(body, path \\ "/webhooks/resend") do
    conn(:post, path, body) |> Plug.Conn.put_req_header("content-type", "application/json")
  end

  describe "read_body/2" do
    test "answers the body and keeps it in assigns" do
      assert {:ok, @body, conn} = RawBodyReader.read_body(request(@body), [])

      assert conn.assigns.raw_body == @body
    end

    test "byte for byte — which is the whole point" do
      # Key order and spacing differ from anything Jason would re-encode.
      body = ~s({ "data" : { "email_id": "x" } ,"type":"email.sent" })

      assert {:ok, ^body, conn} = RawBodyReader.read_body(request(body), [])
      assert conn.assigns.raw_body == body
      refute conn.assigns.raw_body == Jason.encode!(Jason.decode!(body))
    end

    test "an empty body is an empty assign, not a missing one" do
      assert {:ok, "", conn} = RawBodyReader.read_body(request(""), [])
      assert conn.assigns.raw_body == ""
    end

    test "a body read in chunks is joined" do
      # `:length` forces Plug to answer `{:more, _, _}` first.
      body = String.duplicate("a", 5_000)

      assert {:ok, read, conn} = RawBodyReader.read_body(request(body), length: 1_000)

      assert read == body
      assert conn.assigns.raw_body == body
    end
  end

  describe ":paths" do
    test "keeps the body for a path that matches" do
      assert {:ok, @body, conn} =
               RawBodyReader.read_body(request(@body), paths: ["/webhooks/"])

      assert conn.assigns.raw_body == @body
    end

    test "and keeps nothing for one that does not" do
      assert {:ok, @body, conn} =
               RawBodyReader.read_body(request(@body, "/api/orders"), paths: ["/webhooks/"])

      refute Map.has_key?(conn.assigns, :raw_body)
    end

    test "several prefixes" do
      assert {:ok, _, conn} =
               RawBodyReader.read_body(request(@body, "/hooks/resend"),
                 paths: ["/webhooks/", "/hooks/"]
               )

      assert conn.assigns.raw_body == @body
    end

    test "the option is not passed on to Plug.Conn.read_body/2" do
      # `read_body` would raise on an unknown option; it does not, because
      # `:paths` is split off first.
      assert {:ok, _, _} = RawBodyReader.read_body(request(@body), paths: ["/webhooks/"])
    end
  end
end
