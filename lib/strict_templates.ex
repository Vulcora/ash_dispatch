defmodule AshDispatch.TemplateError do
  @moduledoc """
  A template refused by strict templates (`config :ash_dispatch,
  strict_templates: true`). Carries every violation found in the file, each
  with its line.
  """
  defexception [:file, violations: []]

  @impl true
  def message(%{file: file, violations: violations}) do
    """
    #{length(violations)} expression(s) in #{file} would reach the recipient as raw text:

    #{Enum.map_join(violations, "\n", &AshDispatch.StrictTemplates.format_violation/1)}

    #{AshDispatch.StrictTemplates.advice()}
    """
  end
end

defmodule AshDispatch.StrictTemplates do
  @moduledoc ~S"""
  Refuses `.heex` templates with expressions that look like HEEx but are not
  rendered as HEEx.

  ## Why

  ash_dispatch's `.html.heex` templates are rendered by EEx after a
  preprocessor turns `{@assign}` and `attr={...}` into EEx tags. They look
  like HEEx, and most of HEEx works — which is what makes the rest dangerous:

  - `#{...}` in body position is not interpolation in EEx. It is three
    characters, and they go out in the mail. `mix format` writes it for you,
    too: the HEEx formatter turns `#<%= @ticket_number %>` into
    `#{@ticket_number}`.
  - `{if ...}`, `{for ...}`, `{case ...}` (and `unless`, `cond`, `with`) are
    HEEx block expressions. Whether one comes out rendered depends on the
    preprocessor's rules; when it does not, the source of the expression goes
    out to every recipient — and the rest of the mail looks right, so nobody
    notices. That happened: a shipping line reading
    `{if @free_shipping, do: ...}` went out in every order confirmation of one
    consumer for a week.

  A test that renders a mail and looks for expected content does not catch
  this — the raw text is IN the output. So the check is static, on the
  source, with the line of each find.

  ## What is checked

  Body position only. Exempt are:

  - attribute expressions, `href={"mailto:#{@email}"}` — real Elixir, where
    `#{}` interpolates;
  - EEx tags, `<%= ... %>` and `<% ... %>`;
  - `<style>` blocks (CSS braces) and HTML comments.

  `.text.eex` templates are not checked: EEx is what they claim to be.

  ## Enabling

      config :ash_dispatch, strict_templates: true

  Off by default. When on, the `:ash_dispatch` compiler fails the
  build on a violation (every `.heex` under `lib/**/templates/` and
  `priv/ash_dispatch/`), and `AshDispatch.TemplateResolver` refuses to render
  one — `{:error, %AshDispatch.TemplateError{}}` — so a template edited in
  dev without a recompile is caught too. On the send path that error is
  raised rather than sending the letter without its HTML: an action-triggered
  send logs it (the notifier rescues), a direct `Dispatcher.dispatch/3` raises
  to its caller, `dispatch_safely/3` logs it. Since the compiler checks the
  same files, this only happens to a template changed after the build.
  """

  defmodule Violation do
    @moduledoc false
    defstruct [:file, :line, :expression, :kind]
  end

  @blocks ~w(if unless for case cond with)

  @doc "Whether `config :ash_dispatch, strict_templates: true` is set."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:ash_dispatch, :strict_templates, false) == true

  @doc """
  The violations in `content`, the source of the template `file`. `[]` when
  the template is clean. Only `.heex` files are checked; any other name gives
  `[]`.
  """
  @spec check(String.t(), String.t()) :: [Violation.t()]
  def check(content, file) when is_binary(content) do
    if String.ends_with?(to_string(file), ".heex") do
      masked = mask(content)

      (block_expressions(masked, content, file) ++ interpolations(masked, content, file))
      |> Enum.sort_by(& &1.line)
    else
      []
    end
  end

  @doc """
  `:ok`, or `{:error, %AshDispatch.TemplateError{}}` for a template with
  violations.
  """
  @spec validate(String.t(), String.t()) :: :ok | {:error, Exception.t()}
  def validate(content, file) do
    case check(content, file) do
      [] -> :ok
      violations -> {:error, %AshDispatch.TemplateError{file: file, violations: violations}}
    end
  end

  @doc """
  Checks every `.heex` template of a project: `lib/**/templates/**` and
  `priv/ash_dispatch/**` under `root`. Returns all violations.
  """
  @spec check_project(String.t()) :: [Violation.t()]
  def check_project(root \\ File.cwd!()) do
    (Path.wildcard(Path.join(root, "lib/**/templates/**/*.heex")) ++
       Path.wildcard(Path.join(root, "priv/ash_dispatch/**/*.heex")))
    |> Enum.uniq()
    |> Enum.flat_map(fn path -> check(File.read!(path), Path.relative_to(path, root)) end)
  end

  @doc false
  def format_violation(%Violation{} = violation) do
    "  #{violation.file}:#{violation.line}: #{describe(violation.kind)}\n      #{violation.expression}"
  end

  @doc false
  def advice do
    ~S"""
    ash_dispatch renders .heex templates with EEx. Write `<%= if @x, do: "a", else: "b" %>`
    (or `<%= for ... do %> ... <% end %>`), or better: compute the value in
    prepare_template_assigns/2 and print it with {@value}. `#{...}` only interpolates
    inside an attribute string — href={"mailto:#{@email}"}.
    """
  end

  defp describe(:block), do: "HEEx block expression in body position"
  defp describe(:interpolation), do: "\#{...} in body position (EEx does not interpolate it)"

  defp block_expressions(masked, original, file) do
    regex = ~r/\{\s*(?:#{Enum.join(@blocks, "|")})[\s(]/

    regex
    |> Regex.scan(masked, return: :index)
    |> Enum.map(fn [{offset, _len}] ->
      violation(original, offset, file, :block)
    end)
  end

  defp interpolations(masked, original, file) do
    ~r/#\{/
    |> Regex.scan(masked, return: :index)
    |> Enum.map(fn [{offset, _len}] ->
      violation(original, offset, file, :interpolation)
    end)
  end

  defp violation(original, offset, file, kind) do
    <<before::binary-size(^offset), rest::binary>> = original

    %Violation{
      file: file,
      line: count_lines(before),
      expression: snippet(rest),
      kind: kind
    }
  end

  defp count_lines(text), do: 1 + length(:binary.matches(text, "\n"))

  # The expression as written, up to its closing brace (or the end of the
  # line), so the error shows what to look for.
  defp snippet(text) do
    text
    |> String.split("\n", parts: 2)
    |> hd()
    |> take_balanced()
    |> String.slice(0, 120)
    |> String.trim()
  end

  defp take_balanced(line) do
    line
    |> String.graphemes()
    |> Enum.reduce_while({"", 0}, fn char, {acc, depth} ->
      depth =
        case char do
          "{" -> depth + 1
          "}" -> depth - 1
          _ -> depth
        end

      if depth <= 0 and char == "}",
        do: {:halt, {acc <> char, depth}},
        else: {:cont, {acc <> char, depth}}
    end)
    |> elem(0)
  end

  # ── Masking ─────────────────────────────────────────────────────────
  #
  # Exempt regions are overwritten with spaces — newlines kept, so offsets
  # and line numbers in the masked text are those of the original.

  defp mask(content) do
    content
    |> mask_regex(~r/<style\b.*?<\/style>/is)
    |> mask_regex(~r/<!--.*?-->/s)
    |> mask_regex(~r/<%.*?%>/s)
    |> mask_attributes()
  end

  defp mask_regex(content, regex) do
    regex
    |> Regex.scan(content, return: :index)
    |> Enum.reduce(content, fn [{offset, len}], acc -> blank(acc, offset, len) end)
  end

  # `name={...}` — the attribute expression, braces balanced and strings
  # skipped, as the preprocessor's own attribute conversion reads it.
  defp mask_attributes(content) do
    ~r/[\w:@.-]+=\{/
    |> Regex.scan(content, return: :index)
    |> Enum.reduce(content, fn [{offset, len}], acc ->
      start = offset + len

      case inside_tag?(acc, offset) && closing_brace(acc, start) do
        close when is_integer(close) -> blank(acc, offset, close - offset + 1)
        _ -> acc
      end
    end)
  end

  # `Total={if ...}` in running text is body text, not an attribute: only a
  # `name={` after an unclosed `<` is one.
  defp inside_tag?(content, offset) do
    <<before::binary-size(^offset), _::binary>> = content

    case {last_index(before, "<"), last_index(before, ">")} do
      {nil, _} -> false
      {open, nil} -> open >= 0
      {open, close} -> open > close
    end
  end

  defp last_index(text, char) do
    case :binary.matches(text, char) do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end

  defp closing_brace(content, start) do
    <<_::binary-size(^start), rest::binary>> = content
    do_closing_brace(rest, start, 0, false)
  end

  defp do_closing_brace(<<>>, _pos, _depth, _in_string), do: nil

  defp do_closing_brace(<<"\\", _char, rest::binary>>, pos, depth, true),
    do: do_closing_brace(rest, pos + 2, depth, true)

  defp do_closing_brace(<<"\"", rest::binary>>, pos, depth, in_string),
    do: do_closing_brace(rest, pos + 1, depth, not in_string)

  defp do_closing_brace(<<"{", rest::binary>>, pos, depth, false),
    do: do_closing_brace(rest, pos + 1, depth + 1, false)

  defp do_closing_brace(<<"}", _rest::binary>>, pos, 0, false), do: pos

  defp do_closing_brace(<<"}", rest::binary>>, pos, depth, false),
    do: do_closing_brace(rest, pos + 1, depth - 1, false)

  defp do_closing_brace(<<_byte, rest::binary>>, pos, depth, in_string),
    do: do_closing_brace(rest, pos + 1, depth, in_string)

  defp blank(content, offset, len) do
    <<before::binary-size(^offset), region::binary-size(^len), rest::binary>> = content

    before <>
      String.replace(region, ~r/[^\n]/u, fn char -> String.duplicate(" ", byte_size(char)) end) <>
      rest
  end
end
