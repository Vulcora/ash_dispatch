defmodule AshDispatch.SafeRender do
  @moduledoc """
  HTML-safe rendering helpers for `AshDispatch.TemplateResolver`.

  When `TemplateResolver` renders an `email.html.heex` template it
  preprocesses HEEx-style `{@var}` markers into `<%= @var %>` and evaluates
  the result via `EEx.eval_string/2`. Plain EEx does **not** HTML-escape
  interpolated values, so any user-controlled string flowing through
  `prepare_template_assigns/2` (lead name, contract recipient, customer
  comment, etc.) would land raw in the rendered email — a real injection
  vector.

  The preprocessor wraps every auto-converted `{@var}` expansion in
  `AshDispatch.SafeRender.escape/1` for HTML formats so escaping is the
  default, matching Phoenix HEEx semantics.

  ## Opt-out (when you genuinely have safe markup)

      <p>{AshDispatch.SafeRender.raw @already_safe_html}</p>

  `raw/1` returns its argument unchanged and is recognized as a "not a
  bare `@var`" expression by the preprocessor, so it's emitted as plain
  `<%= raw(@x) %>` without the escape wrapper.

  ## Phoenix.HTML interop

  If an assign value is a `{:safe, iodata}` tuple (Phoenix's `Phoenix.HTML.Safe`
  output) `escape/1` returns the iodata as-is — the value already
  promises it is escaped.
  """

  @doc """
  Escape a value for safe inclusion in HTML output.

  - `nil` → `""` (so `{@missing_field}` doesn't render the string "nil")
  - `binary` → HTML-escaped
  - `integer` / `float` / `atom` → string-converted (no escape needed —
    these can't contain markup characters that change meaning)
  - `{:safe, iodata}` → returned unchanged (already escaped by caller)
  - Anything else → `to_string/1` then escape
  """
  @spec escape(any()) :: iodata()
  def escape(nil), do: ""
  def escape({:safe, iodata}), do: iodata
  def escape(value) when is_integer(value) or is_float(value), do: to_string(value)
  def escape(value) when is_atom(value), do: Atom.to_string(value)

  def escape(value) when is_binary(value) do
    # In-line escape so we don't take a new dependency on Plug.HTML or
    # phoenix_html — the substitution table matches both.
    do_escape(value, [])
  end

  # Anything else — fall back to String.Chars if implemented. This catches
  # Date, NaiveDateTime, Decimal, custom structs, etc. Raises if the type
  # doesn't have a String.Chars impl (e.g. plain maps, lists, tuples) —
  # better to fail loud than silently render `<<1,2,3>>` from an iolist.
  def escape(value), do: value |> to_string() |> escape()

  @doc """
  Mark a value as already-safe HTML so the preprocessor's auto-escape
  is bypassed.

  In templates:

      <p>{AshDispatch.SafeRender.raw @trusted_html}</p>

  Returns its argument unchanged — the wrapper is only meaningful as a
  signal to the HEEx preprocessor, which sees `raw(@x)` is not a bare
  `@var` and emits `<%= raw(@x) %>` without escape.
  """
  @spec raw(value) :: value when value: any()
  def raw(value), do: value

  # ── internals ──────────────────────────────────────────────────

  # Single-pass HTML escape — same substitutions as Plug.HTML.html_escape/1.
  defp do_escape(<<>>, acc), do: IO.iodata_to_binary(Enum.reverse(acc))
  defp do_escape(<<?<, rest::binary>>, acc), do: do_escape(rest, ["&lt;" | acc])
  defp do_escape(<<?>, rest::binary>>, acc), do: do_escape(rest, ["&gt;" | acc])
  defp do_escape(<<?&, rest::binary>>, acc), do: do_escape(rest, ["&amp;" | acc])
  defp do_escape(<<?", rest::binary>>, acc), do: do_escape(rest, ["&quot;" | acc])
  defp do_escape(<<?', rest::binary>>, acc), do: do_escape(rest, ["&#39;" | acc])
  defp do_escape(<<c::utf8, rest::binary>>, acc), do: do_escape(rest, [<<c::utf8>> | acc])
end
