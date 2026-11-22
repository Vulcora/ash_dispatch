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

  Name the paths that need a raw body. Nothing but the webhook route does, and
  the raw body of a file upload has no business sitting in `conn.assigns`:

      plug Plug.Parsers,
        parsers: [:urlencoded, :multipart, :json],
        pass: ["*/*"],
        json_decoder: Jason,
        body_reader:
          {AshDispatch.Plugs.RawBodyReader, :read_body, [paths: ["/webhooks/"]]}

  `:paths` is a list of path prefixes. A request whose path starts with none of
  them is read by `Plug.Conn.read_body/2` directly and nothing is kept.

  Without `:paths` every request through those parsers keeps its body. That
  works, and it is more than anyone needs.

  ## Where it ends up

  `conn.assigns[:raw_body]` — a binary.
  `AshDispatch.Plugs.ResendWebhook` reads it from there, and
  `Resend.verify/4` takes it directly.

  ## The size limit still applies

  `{:more, _, _}` from a body reader is how `Plug.Parsers` is told the body is
  **too large**: its JSON parser turns that into `:too_large`, which is a 413.
  A reader that loops on it until the body ends has removed the limit, and an
  unauthenticated POST of any size is then read into memory in full.

  So this reader joins chunks only up to `:length` — `Plug.Parsers`' own
  option, defaulting to Plug's own 8 MB — and returns `{:more, …}` at the cap,
  which is to say it refuses exactly where Plug would have.

  ## Use `:paths`

  The first form above keeps the raw body of **every** request that goes
  through those parsers. Nothing needs that but the webhook route, and the raw
  body of a file upload has no business sitting in `conn.assigns`. Prefer the
  second form.
  """

  # Plug's own default, so a host that passes no `:length` gets the limit it
  # would have had without this reader in the way.
  @default_length 8_000_000

  # Plug is an optional dependency, and this module names `Plug.Conn` only at
  # runtime — a host that cannot receive a request does not need it to compile.
  @compile {:no_warn_undefined, Plug.Conn}

  @doc """
  Reads the body, and keeps it in `conn.assigns[:raw_body]`.

  The return shape `Plug.Parsers` expects: `{:ok, body, conn}`,
  `{:more, partial, conn}` or `{:error, reason}`. `{:more, …}` is the refusal
  — see the moduledoc.
  """
  @spec read_body(term(), keyword()) ::
          {:ok, binary(), term()} | {:more, binary(), term()} | {:error, term()}
  def read_body(conn, opts \\ []) do
    {mine, plug_opts} = Keyword.split(opts, [:paths])

    if keep?(conn, Keyword.get(mine, :paths)) do
      read_and_keep(conn, plug_opts, [], 0, cap(plug_opts))
    else
      Plug.Conn.read_body(conn, plug_opts)
    end
  end

  defp cap(opts) do
    case Keyword.get(opts, :length, @default_length) do
      length when is_integer(length) and length > 0 -> length
      _ -> @default_length
    end
  end

  defp read_and_keep(conn, opts, acc, size, cap) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, chunk, conn} ->
        body = acc |> Enum.reverse([chunk]) |> IO.iodata_to_binary()

        if byte_size(body) > cap do
          {:more, chunk, conn}
        else
          {:ok, body, Plug.Conn.assign(conn, :raw_body, body)}
        end

      # A body in several chunks, under the cap: joined, because a signature
      # over part of a body matches nothing and a webhook that arrived split
      # would have failed verification for no reason anyone could see.
      #
      # AT the cap this same shape is passed ON, which is Plug's own refusal:
      # the parser turns it into `:too_large` and the request gets a 413.
      # Looping past it is how a reader silently removes `:length`.
      {:more, chunk, conn} ->
        size = size + byte_size(chunk)

        if size >= cap do
          {:more, chunk, conn}
        else
          read_and_keep(conn, opts, [chunk | acc], size, cap)
        end

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
