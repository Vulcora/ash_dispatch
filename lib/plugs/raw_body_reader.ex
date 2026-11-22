defmodule AshDispatch.Plugs.RawBodyReader do
  @moduledoc """
  A `Plug.Parsers` body reader that keeps the raw request body.

  A signed webhook can only be verified against the bytes that were signed. A
  JSON parser consumes the body and hands you a map, and re-encoding that map
  gives different bytes — different key order, different whitespace, a
  different number format — so the signature never matches. Every host that
  wired `AshDispatch.WebhookHandlers.Resend.verify/4` into a controller had to
  write this first, and four of them wrote the same twelve lines.

  ## Setup

  In your endpoint, for the webhook path only:

      plug Plug.Parsers,
        parsers: [:urlencoded, :multipart, :json],
        pass: ["*/*"],
        json_decoder: Jason,
        body_reader: {AshDispatch.Plugs.RawBodyReader, :read_body, []}

  Narrower, and better, is to keep every other request out of it — the raw
  body of a file upload has no business sitting in `conn.assigns`:

      plug Plug.Parsers,
        parsers: [:json],
        json_decoder: Jason,
        body_reader:
          {AshDispatch.Plugs.RawBodyReader, :read_body, [paths: ["/webhooks/"]]}

  `:paths` is a list of path prefixes. A request whose path starts with none of
  them is read normally and nothing is kept.

  ## Where it ends up

  `conn.assigns[:raw_body]` — a binary.
  `AshDispatch.Plugs.ResendWebhook` reads it from there, and
  `Resend.verify/4` takes it directly.

  A body read in several chunks (`{:more, _, _}`) is joined, so the assign is
  the whole body however the client sent it. `Plug.Parsers`'s own `:length`
  limit still applies: a body over it is refused by Plug before this returns.
  """

  # Plug is an optional dependency, and this module names `Plug.Conn` only at
  # runtime — a host that cannot receive a request does not need it to compile.
  @compile {:no_warn_undefined, Plug.Conn}

  @doc """
  Reads the body, and keeps it in `conn.assigns[:raw_body]`.

  The return shape `Plug.Parsers` expects: `{:ok, body, conn}`,
  `{:more, partial, conn}` or `{:error, reason}`.
  """
  @spec read_body(term(), keyword()) :: {:ok, binary(), term()} | {:error, term()}
  def read_body(conn, opts \\ []) do
    {mine, plug_opts} = Keyword.split(opts, [:paths])

    if keep?(conn, Keyword.get(mine, :paths)) do
      read_and_keep(conn, plug_opts, [])
    else
      Plug.Conn.read_body(conn, plug_opts)
    end
  end

  defp read_and_keep(conn, opts, acc) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, chunk, conn} ->
        body = acc |> Enum.reverse([chunk]) |> IO.iodata_to_binary()
        {:ok, body, Plug.Conn.assign(conn, :raw_body, body)}

      # A body in several chunks. Joined rather than kept as the first chunk:
      # a signature over part of a body matches nothing, and a webhook that
      # arrived split would have failed verification for no reason anyone
      # could see.
      {:more, chunk, conn} ->
        read_and_keep(conn, opts, [chunk | acc])

      other ->
        other
    end
  end

  defp keep?(_conn, nil), do: true

  defp keep?(conn, paths) when is_list(paths) do
    path = "/" <> Enum.join(Map.get(conn, :path_info, []), "/")
    Enum.any?(paths, &String.starts_with?(path, &1))
  end

  defp keep?(_conn, _paths), do: true
end
