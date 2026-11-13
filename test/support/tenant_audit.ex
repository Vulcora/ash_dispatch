defmodule AshDispatch.Test.TenantAudit do
  @moduledoc """
  Walks the library's source and reports every place a tenant reaches Ash or
  the repo without going through `AshDispatch.Tenancy`.

  `test/tenancy/compatibility_test.exs` used two text searches for this — a
  `String.contains?` for `"Ash.Changeset.set_tenant("` and a regex for
  `tenant:` on the same line as an `Ash.` call. They called themselves the
  structural proof that "every read and write the library makes takes its
  tenant from `AshDispatch.Tenancy.opts/2`", and ordinary Elixir got past both
  of them:

    * `Ash.Query.set_tenant/2` — the string search named `Ash.Changeset` only,
      and `lib/tenancy.ex` itself uses the `Ash.Query` one;
    * `Ash.Query.for_read(res, :read, %{}, tenant: t)` and
      `Ash.Changeset.for_create/4` — the constructors take `tenant:` too, and
      neither search looked at them;
    * `opts = [tenant: t]; Ash.get(res, id, opts)` — `tenant:` is not on the
      call's line;
    * a call spread over several lines, or with a `)` in its first argument —
      `[^)\\n]*` stops at the first of either;
    * `apply(Ash.Changeset, :set_tenant, [cs, t])`;
    * a raw `prefix:` on the repo, which neither search mentioned at all.

  It also matched its own documentation: prose in a `@moduledoc` that *shows*
  `Ash.read_one(tenant: ...)` was reported as a call site.

  So it is an AST walk now. It reads structure, so a string is a string, a
  newline is nothing, and a tenant in a variable is followed one assignment
  back.

  ## What counts

  An **Ash-facing call** is any `Ash.*`, `Ash.Query.*`, `Ash.Changeset.*` or
  `Ash.ActionInput.*` call, and any call on a `repo()`. A finding is one of:

    * `:option` — such a call is given a `tenant:` (or a repo call a
      `prefix:`) whose value is not an `AshDispatch.Tenancy` call;
    * `:tainted` — such a call is given a variable that was assigned a
      keyword list holding one;
    * `:set_tenant` — `Ash.Query.set_tenant/2` or
      `Ash.Changeset.set_tenant/2` called outside `AshDispatch.Tenancy`;
    * `:dynamic` — `apply/3` on either of those.

  A `tenant:` inside a **map** literal is not a finding: that is an action
  *argument* (the `tenant` column filter), which is a different question from
  which schema the call runs in, and the resources take it as a declared
  argument.
  """

  @ash_modules [["Ash"], ["Ash", "Query"], ["Ash", "Changeset"], ["Ash", "ActionInput"]]
  @tenant_setters [["Ash", "Query"], ["Ash", "Changeset"]]
  @option_keys [:tenant, :prefix]

  @doc "Every file the audit reads. Public so a test can assert it found the library."
  @spec files() :: [Path.t()]
  def files, do: "lib/**/*.ex" |> Path.wildcard() |> Enum.sort()

  @doc """
  Findings for the whole library, `[{kind, file, line, snippet}, ...]`.

  `allow` names files that are permitted to do it — `lib/tenancy.ex`, which is
  the one module that asks the resource before it mentions a tenant to Ash.
  """
  @spec findings([Path.t()]) :: [{atom(), Path.t(), pos_integer() | nil, String.t()}]
  def findings(allow \\ ["lib/tenancy.ex"]) do
    files()
    |> Enum.reject(&(&1 in allow))
    |> Enum.flat_map(&file_findings/1)
  end

  @doc false
  def file_findings(path), do: path |> File.read!() |> source_findings(path)

  @doc """
  Findings for one piece of source. The guard test feeds it snippets, so what
  the audit catches is itself asserted rather than assumed.
  """
  @spec source_findings(String.t(), Path.t()) :: [
          {atom(), Path.t(), pos_integer() | nil, String.t()}
        ]
  def source_findings(source, path \\ "(source)") do
    ast = Code.string_to_quoted!(source)
    tainted = tainted_variables(ast)

    {_ast, found} =
      Macro.prewalk(ast, [], fn node, acc ->
        {node, acc ++ node_findings(node, path, tainted)}
      end)

    found
  end

  # ── the rules ───────────────────────────────────────────────────────────

  defp node_findings(
         {{:., _, [{:__aliases__, _, mods}, :set_tenant]}, meta, _args} = node,
         path,
         _
       ) do
    if alias_path(mods) in @tenant_setters do
      [{:set_tenant, path, meta[:line], snippet(node)}]
    else
      []
    end
  end

  defp node_findings({:apply, meta, [{:__aliases__, _, mods}, :set_tenant, _]} = node, path, _) do
    if alias_path(mods) in @tenant_setters do
      [{:dynamic, path, meta[:line], snippet(node)}]
    else
      []
    end
  end

  defp node_findings({{:., _, [{:__aliases__, _, mods}, _fun]}, meta, args} = node, path, tainted) do
    if alias_path(mods) in @ash_modules do
      call_findings(args, node, meta, path, tainted)
    else
      []
    end
  end

  # `Config.repo().update_all(query, [], prefix: tenant)` and friends.
  defp node_findings({{:., _, [{{:., _, [_, :repo]}, _, _}, _fun]}, meta, args} = node, path, t) do
    call_findings(args, node, meta, path, t)
  end

  defp node_findings(_node, _path, _tainted), do: []

  defp call_findings(args, node, meta, path, tainted) do
    cond do
      Enum.any?(args, &bad_option?/1) ->
        [{:option, path, meta[:line], snippet(node)}]

      Enum.any?(args, &mentions_tainted?(&1, tainted)) ->
        [{:tainted, path, meta[:line], snippet(node)}]

      true ->
        []
    end
  end

  # ── finding a `tenant:` that AshDispatch.Tenancy did not produce ────────

  defp bad_option?(ast) do
    ast
    |> option_pairs()
    |> Enum.any?(fn {_key, value} -> not from_tenancy?(value) end)
  end

  # Every `tenant:`/`prefix:` pair in a KEYWORD position. Map literals are
  # pruned: `%{tenant: t}` is an action argument, not an option.
  defp option_pairs(ast) do
    {_ast, pairs} =
      Macro.prewalk(ast, [], fn
        {:%{}, _, _}, acc -> {nil, acc}
        {key, value} = pair, acc when key in @option_keys -> {pair, [{key, value} | acc]}
        node, acc -> {node, acc}
      end)

    pairs
  end

  defp from_tenancy?({{:., _, [{:__aliases__, _, mods}, fun]}, _, _}) do
    List.last(mods) == :Tenancy and fun in [:opts, :prefix, :receipt_prefix]
  end

  # `|> Tenancy.opts(...)` and the like: a pipe into the Tenancy call.
  defp from_tenancy?({:|>, _, [_left, right]}), do: from_tenancy?(right)

  defp from_tenancy?(_other), do: false

  # ── one assignment back ─────────────────────────────────────────────────

  defp tainted_variables(ast) do
    {_ast, names} =
      Macro.prewalk(ast, [], fn
        {:=, _, [{name, _, context}, value]} = node, acc
        when is_atom(name) and is_atom(context) ->
          if bad_option?(value), do: {node, [name | acc]}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(names)
  end

  defp mentions_tainted?(_ast, []), do: false

  defp mentions_tainted?(ast, tainted) do
    {_ast, found} =
      Macro.prewalk(ast, false, fn
        {name, _, context} = node, acc when is_atom(name) and is_atom(context) ->
          {node, acc or name in tainted}

        node, acc ->
          {node, acc}
      end)

    found
  end

  # `{:__aliases__, _, mods}` is not always a list of atoms: `__MODULE__.f()`
  # puts an AST node in there. Such a call is not one of ours.
  defp alias_path(mods) do
    if Enum.all?(mods, &is_atom/1), do: Enum.map(mods, &Atom.to_string/1)
  end

  defp snippet(node) do
    node |> Macro.to_string() |> String.split("\n") |> hd() |> String.slice(0, 120)
  end
end
