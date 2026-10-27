defmodule AshDispatch.Test do
  @moduledoc ~S"""
  Test helpers for apps: render every letter the app can send, and fail on
  any that would go out broken.

  The one-line test:

      test "every mail renders" do
        assert AshDispatch.Test.assert_all_render(seeds: 25) == 42
      end

  `assert_all_render/1` renders every row of `AshDispatch.Preview.events/0`
  (event × channel × variant × audience) from its sample data, once per seed,
  through the send path's own renderer, and fails — listing every finding —
  when a letter:

  - could not be rendered at all;
  - is an email with an empty subject, or with neither an HTML nor a text
    body;
  - still contains template source: `<%`, `{@`, `#{`, a HEEx block
    expression (`{if `, `{for `, `{case `, `{unless `, `{cond `, `{with `), or
    `TODO`.

  It returns how many letters it rendered. Assert on that number, exactly: a
  test that turns green because nothing was rendered is the failure it
  exists to prevent, and a hard-coded count goes red when an event loses a
  channel or a template, instead of quietly checking less.

  ## Why the rendered output and not the templates

  `AshDispatch.StrictTemplates` checks the source. This checks what comes
  out, which also catches what no source check can: an expression that was
  converted but still printed its own code, a value that renders as
  `#{...}` because it was built with the wrong quotes, an assign that came
  out empty.

  ## Options

  - `:seeds` - an integer `n` (seeds `1..n`) or a list of seeds. Default `[1]`
  - `:only` / `:except` - event ids to include or leave out
  - `:transports` - only these transports (default: all)
  - `:forbid` - more strings that must not appear (e.g. `["lorem ipsum"]`)
  - any other option is passed to `AshDispatch.Preview.render/3` (`:locale`,
    `:variables`, …)
  """

  alias AshDispatch.Preview

  # ExUnit ships with Elixir but is not started in a release; these helpers
  # only ever run inside a test.
  @compile {:no_warn_undefined, ExUnit.AssertionError}

  @markers ["<%", "{@", "\#{", "{if ", "{for ", "{case ", "{unless ", "{cond ", "{with ", "TODO"]

  @render_opts_skip [:seeds, :only, :except, :transports, :forbid]

  @typedoc "One rendered letter and what is wrong with it (`[]` when nothing)."
  @type result :: %{
          row: map(),
          seed: integer(),
          rendered: Preview.Rendered.t() | nil,
          problems: [String.t()]
        }

  @doc """
  Renders every row of `AshDispatch.Preview.events/0` for every seed and
  returns one `t:result/0` per letter. See the moduledoc for the options and
  the checks.
  """
  @spec render_all(keyword()) :: [result()]
  def render_all(opts \\ []) do
    render_opts = Keyword.drop(opts, @render_opts_skip)
    forbid = @markers ++ List.wrap(Keyword.get(opts, :forbid, []))

    for row <- rows(opts), seed <- seeds(opts), result <- render_row(row, seed, render_opts) do
      case result do
        {:ok, rendered} ->
          %{row: row, seed: seed, rendered: rendered, problems: problems(rendered, forbid)}

        {:error, reason} ->
          %{row: row, seed: seed, rendered: nil, problems: ["could not render: #{reason}"]}
      end
    end
  end

  @doc """
  Fails with every finding of `render_all/1`, or returns the number of
  letters rendered. Fails as well when that number is zero.
  """
  @spec assert_all_render(keyword()) :: non_neg_integer()
  def assert_all_render(opts \\ []) do
    results = render_all(opts)

    case Enum.reject(results, &(&1.problems == [])) do
      [] when results == [] ->
        raise ExUnit.AssertionError,
          message:
            "AshDispatch.Test.assert_all_render/1 rendered nothing — no events with " <>
              "channels were found (is :otp_app configured, and are the domains listed?)"

      [] ->
        length(results)

      failing ->
        raise ExUnit.AssertionError,
          message: """
          #{length(failing)} of #{length(results)} letters would go out broken:

          #{Enum.map_join(failing, "\n", &format_failure/1)}
          """
    end
  end

  @doc """
  The problems `render_all/1` would report for one rendered letter — `[]`
  when there are none. For checking a letter rendered some other way, e.g. by
  `AshDispatch.Preview.render/3` from a specific record. Takes `:forbid`.
  """
  @spec problems_for(Preview.Rendered.t(), keyword()) :: [String.t()]
  def problems_for(%Preview.Rendered{} = rendered, opts \\ []) do
    problems(rendered, @markers ++ List.wrap(Keyword.get(opts, :forbid, [])))
  end

  # ── Rendering ───────────────────────────────────────────────────────

  defp rows(opts) do
    only = Keyword.get(opts, :only)
    except = Keyword.get(opts, :except, [])
    transports = Keyword.get(opts, :transports)

    Preview.events()
    |> Enum.filter(fn row ->
      (is_nil(only) or row.event_id in only) and row.event_id not in except and
        (is_nil(transports) or row.transport in transports)
    end)
  end

  defp seeds(opts) do
    case Keyword.get(opts, :seeds, [1]) do
      n when is_integer(n) and n > 0 -> Enum.to_list(1..n)
      list when is_list(list) -> list
    end
  end

  defp render_row(row, seed, render_opts) do
    case Preview.render(row, :sample, Keyword.put(render_opts, :seed, seed)) do
      {:ok, []} -> [{:error, "no channel matched #{describe(row)}"}]
      {:ok, rendered} -> Enum.map(rendered, &{:ok, &1})
      {:error, reason} -> [{:error, to_string_reason(reason)}]
    end
  end

  # ── Checks ──────────────────────────────────────────────────────────

  defp problems(%Preview.Rendered{error: error}, _forbid) when is_binary(error),
    do: ["could not render: #{error}"]

  defp problems(%Preview.Rendered{} = rendered, forbid) do
    envelope_problems(rendered) ++
      Enum.flat_map(fields(rendered), fn {field, text} ->
        leftovers(field, text, forbid)
      end)
  end

  defp envelope_problems(%{transport: :email} = rendered) do
    no_body? = blank?(rendered.html_body) and blank?(rendered.text_body)

    [
      blank?(rendered.subject) && "empty subject",
      no_body? && "neither an HTML nor a text body"
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp envelope_problems(_rendered), do: []

  defp fields(rendered) do
    [
      subject: rendered.subject,
      html_body: without_styles(rendered.html_body),
      text_body: rendered.text_body,
      title: rendered.title,
      message: rendered.message
    ]
    |> Enum.filter(fn {_field, text} -> is_binary(text) end)
  end

  defp leftovers(field, text, forbid) do
    forbid
    |> Enum.filter(&leftover?(text, &1))
    |> Enum.map(fn marker -> "#{field} contains `#{marker}`: …#{excerpt(text, marker)}…" end)
  end

  # `{@` inside a `#{@...}` is the same finding as the `#{`, reported once.
  defp leftover?(text, "{@"), do: Regex.match?(~r/(?<!#)\{@/, text)
  defp leftover?(text, marker), do: String.contains?(text, marker)

  defp excerpt(text, marker) do
    case String.split(text, marker, parts: 2) do
      [before, after_marker] ->
        (String.slice(before, -20, 20) <> marker <> String.slice(after_marker, 0, 60))
        |> String.replace(~r/\s+/, " ")
        |> String.trim()

      _ ->
        ""
    end
  end

  # CSS is not template output: a minified `@supports (...){@media ...}` would
  # read as a leftover `{@`.
  defp without_styles(nil), do: nil
  defp without_styles(html), do: String.replace(html, ~r/<style\b.*?<\/style>/is, "")

  defp blank?(nil), do: true
  defp blank?(text) when is_binary(text), do: String.trim(text) == ""

  # ── Reporting ───────────────────────────────────────────────────────

  defp format_failure(%{row: row, seed: seed, problems: problems}) do
    "  #{describe(row)} (seed #{seed})\n" <> Enum.map_join(problems, "\n", &("    - " <> &1))
  end

  defp describe(row) do
    variant = if row.variant, do: " variant #{row.variant}", else: ""
    "#{row.event_id} #{row.transport}/#{row.audience}#{variant}"
  end

  defp to_string_reason(reason) when is_binary(reason), do: reason
  defp to_string_reason(reason), do: inspect(reason)
end
