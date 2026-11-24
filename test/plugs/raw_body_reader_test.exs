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

    test "a body in chunks UNDER the cap is joined" do
      # `:read_length` splits the read; `:length` is the cap and is not
      # reached, so the chunks are joined and the signature can be checked
      # against the whole body.
      body = String.duplicate("a", 5_000)

      assert {:ok, read, conn} =
               RawBodyReader.read_body(request(body), length: 50_000, read_length: 1_000)

      assert read == body
      assert conn.assigns.raw_body == body
    end
  end

  describe "the documented wiring, through real Plug.Parsers" do
    # `Plug.Parsers` calls a body reader as
    # `apply(mod, fun, [conn, opts | args])`, so the `args` of its MFA are
    # EXTRA ARGUMENTS, not options — and it does not check the arity. So the
    # only wiring the guide showed raised `UndefinedFunctionError` on every
    # JSON request in the whole application. Every other test in this file
    # folds `paths:` into the options by hand and misses it completely.
    defp parse!(conn, args) do
      Plug.Parsers.call(
        conn,
        Plug.Parsers.init(
          parsers: [:json],
          json_decoder: Jason,
          body_reader: {RawBodyReader, :read_body, args}
        )
      )
    end

    test "args: [paths: [...]] — the form the guide shows" do
      conn = parse!(request(@body), paths: ["/webhooks/"])

      assert conn.assigns.raw_body == @body
      assert conn.body_params == Jason.decode!(@body)
    end

    test "args: [] — the other documented form" do
      conn = parse!(request(@body), [])

      assert conn.assigns.raw_body == @body
    end

    test "and a path that does not match keeps nothing, through the parser" do
      conn = parse!(request(@body, "/api/orders"), paths: ["/webhooks/"])

      refute Map.has_key?(conn.assigns, :raw_body)
      assert conn.body_params == Jason.decode!(@body)
    end

    test "several prefixes as one extra argument" do
      conn = parse!(request(@body, "/hooks/resend"), paths: ["/webhooks/", "/hooks/"])

      assert conn.assigns.raw_body == @body
    end

    test "an extra argument that is not options is ignored, not a crash" do
      conn = parse!(request(@body), [:nonsense])

      assert conn.assigns.raw_body == @body
    end
  end

  describe "the size limit" do
    # `{:more, _, _}` from a body reader is how `Plug.Parsers` is told the
    # body is too large: its JSON parser turns that into `:too_large`, a 413.
    # A reader that loops on it has removed `:length`, and an unauthenticated
    # POST of any size is then read into memory in full. This is the finding
    # that blocked the release, and the previous version of this file
    # enshrined the defect.
    test "a body over :length is refused, not read to the end" do
      body = String.duplicate("a", 5_000)

      assert {:more, _partial, conn} = RawBodyReader.read_body(request(body), length: 1_000)

      # Nothing was kept: there is no verified body to keep.
      refute Map.has_key?(conn.assigns, :raw_body)
    end

    test "the refusal is what Plug.Parsers turns into a 413" do
      body = String.duplicate("a", 5_000)
      conn = request(body)

      assert_raise Plug.Parsers.RequestTooLargeError, fn ->
        Plug.Parsers.call(
          conn,
          Plug.Parsers.init(
            parsers: [:json],
            json_decoder: Jason,
            length: 1_000,
            body_reader: {RawBodyReader, :read_body, []}
          )
        )
      end
    end

    test "the default cap is Plug's own 8 MB, not unlimited" do
      # A host following the documented setup passes no `:length`, and must
      # get the limit it would have had without this reader in the way.
      body = String.duplicate("a", 9_000_000)

      assert {:more, _partial, _conn} = RawBodyReader.read_body(request(body), [])
    end

    test "a body just under the default cap still comes through whole" do
      body = String.duplicate("a", 100_000)

      assert {:ok, ^body, conn} = RawBodyReader.read_body(request(body), [])
      assert conn.assigns.raw_body == body
    end

    test "a nonsense :length falls back on the default rather than meaning none" do
      body = String.duplicate("a", 1_000)

      assert {:ok, ^body, _conn} = RawBodyReader.read_body(request(body), length: :unlimited)
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
