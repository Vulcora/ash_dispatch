defmodule AshDispatch.StrictTemplatesTest do
  @moduledoc ~S"""
  `strict_templates: true` refuses `.heex` templates whose expressions would
  reach the recipient as raw text — in the compiler and in TemplateResolver —
  with the file and line of each.

  The bug it exists for: `Frakt: {if @free_shipping, do: "Fri frakt", else:
  "..."}` went out as raw text in every order confirmation of one consumer
  for a week, and `#{String.slice(@ticket.id, 0..7)}` in a ticket mail —
  written there by `mix format`, not by anyone.
  """
  use ExUnit.Case, async: false

  alias AshDispatch.StrictTemplates
  alias AshDispatch.TemplateResolver

  defp check(source), do: StrictTemplates.check(source, "email.html.heex")

  describe "check/2" do
    test "refuses HEEx block expressions in body position, with the line" do
      source = """
      <p>Hello {@name}</p>
      <p>Shipping: {if @free_shipping, do: "Free", else: "Invoiced"}</p>
      {for item <- @items do}
      {case @status do}
      """

      assert [
               %{
                 line: 2,
                 kind: :block,
                 expression: ~s({if @free_shipping, do: "Free", else: "Invoiced"})
               },
               %{line: 3, kind: :block},
               %{line: 4, kind: :block}
             ] = check(source)
    end

    test "refuses \#{...} in body position" do
      assert [%{line: 1, kind: :interpolation, expression: "\#{String.slice(@id, 0..7)}"}] =
               check("<p>Ticket \#{String.slice(@id, 0..7)}</p>")
    end

    test "allows what renders: assigns, calls, attributes, EEx, CSS, comments" do
      source = """
      <style>
        .button { color: red; } @media (max-width: 600px) { .x { width: 100% } }
      </style>
      <!-- {if this were rendered} -->
      <a href={"mailto:\#{@email}"} style={"color: \#{@color}"}>{@email}</a>
      <p>{AshDispatch.SafeRender.raw(@html)}</p>
      <%= if @free_shipping, do: "Free", else: "Invoiced" %>
      <%= for item <- @items do %><li>{item.name}</li><% end %>
      """

      assert check(source) == []
    end

    test "a quoted attribute is body text to EEx — \#{} there is raw too" do
      assert [%{kind: :interpolation}] = check(~s(<a href="mailto:\#{@email}">x</a>))
    end

    test "name={...} in running text is body text, not an attribute" do
      assert [%{kind: :block}] = check("<p>Total={if @discount, do: 1}</p>")
    end

    test "only .heex is checked" do
      assert StrictTemplates.check("\#{x} {if a, do: b}", "email.text.eex") == []
    end

    test "lines are counted through masked regions" do
      source = "<style>\n.a { }\n</style>\n<%= \n @x %>\n{if @x, do: 1}\n"
      assert [%{line: 6}] = check(source)
    end
  end

  describe "TemplateResolver" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "ash_dispatch_strict_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "email.html.heex"), "<p>Hi</p>\n<p>{if @vip, do: \"VIP\"}</p>\n")

      on_exit(fn ->
        File.rm_rf!(dir)
        Application.delete_env(:ash_dispatch, :strict_templates)
      end)

      render = fn ->
        TemplateResolver.render(
          template_path: dir,
          format: :html,
          transport: :email,
          assigns: %{vip: true}
        )
      end

      %{render: render, dir: dir}
    end

    test "off (the 0.9 default): the template renders as before", %{render: render} do
      assert {:ok, _} = render.()
    end

    test "on: the template is refused with its file and line", %{render: render, dir: dir} do
      Application.put_env(:ash_dispatch, :strict_templates, true)

      assert {:error, %AshDispatch.TemplateError{file: file, violations: [violation]} = error} =
               render.()

      assert file =~ Path.basename(dir)
      assert violation.line == 2
      assert Exception.message(error) =~ "email.html.heex:2"
      assert Exception.message(error) =~ "{if @vip"
    end
  end

  describe "the :ash_dispatch compiler" do
    setup do
      root =
        Path.join(System.tmp_dir!(), "ash_dispatch_compile_#{System.unique_integer([:positive])}")

      templates = Path.join(root, "lib/my_app/orders/events/created/templates")
      File.mkdir_p!(templates)
      File.write!(Path.join(templates, "email.html.heex"), "<p>Ok {@x}</p>\n<p>\#{@x}</p>\n")

      on_exit(fn ->
        File.rm_rf!(root)
        Application.delete_env(:ash_dispatch, :strict_templates)
      end)

      %{root: root}
    end

    test "check_project/1 finds every violation under lib/**/templates", %{root: root} do
      assert [%{file: file, line: 2, kind: :interpolation}] = StrictTemplates.check_project(root)
      assert file == "lib/my_app/orders/events/created/templates/email.html.heex"
    end

    test "fails the build with a diagnostic per violation when strict", %{root: root} do
      Application.put_env(:ash_dispatch, :strict_templates, true)

      {result, _output} =
        File.cd!(root, fn ->
          ExUnit.CaptureIO.with_io(:stderr, fn -> Mix.Tasks.Compile.AshDispatch.run([]) end)
        end)

      assert {:error, [diagnostic]} = result
      assert diagnostic.severity == :error
      assert diagnostic.position == 2
      assert diagnostic.file =~ "email.html.heex"
    end

    test "passes when strict is off", %{root: root} do
      assert {:ok, []} = File.cd!(root, fn -> Mix.Tasks.Compile.AshDispatch.run([]) end)
    end
  end
end
