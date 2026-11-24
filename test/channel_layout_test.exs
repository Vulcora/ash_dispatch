defmodule AshDispatch.ChannelLayoutTest do
  @moduledoc """
  A layout per channel.

  `TemplateResolver` has had a layout subdirectory per layout since 0.5, and
  the dispatcher never passed a `layout:` — so the only reachable layout was
  the one default per transport, and a brand edition (one frame per brand, one
  frame for urgent mail) was not expressible. `layout` and `layout_from` on the
  channel are that way, and this file pins three things:

  1. the resolver carries the two fields, for every input form;
  2. `Dispatcher.resolve_channel_layout/2`'s precedence, and that it refuses a
     name that is not a name — `layout_from` reads an arbitrary record field,
     and the value becomes a path segment;
  3. the resolver really renders through the named subdirectory, and really
     falls back on the default layout.
  """
  use ExUnit.Case, async: false

  alias AshDispatch.Channel
  alias AshDispatch.ChannelResolver
  alias AshDispatch.Context
  alias AshDispatch.Dispatcher
  alias AshDispatch.TemplateResolver

  @moduletag :capture_log

  defp ctx(data \\ %{}) do
    %Context{
      event_id: "test.event",
      resource_key: :record,
      data: data,
      variables: %{},
      locale: "en"
    }
  end

  describe "the resolver carries layout and layout_from" do
    test "from a DSL entry" do
      result =
        ChannelResolver.to_channel_struct(%AshDispatch.Dsl.Channel{
          transport: :email,
          audience: :user,
          layout: :urgent,
          layout_from: :brand
        })

      assert result.layout == :urgent
      assert result.layout_from == :brand
    end

    test "from a map" do
      result =
        ChannelResolver.to_channel_struct(%{
          transport: :email,
          audience: :user,
          layout: "urgent",
          layout_from: :brand
        })

      assert result.layout == "urgent"
      assert result.layout_from == :brand
    end

    test "from a keyword list" do
      result =
        ChannelResolver.to_channel_struct(
          transport: :email,
          audience: :user,
          layout: :urgent,
          layout_from: :brand
        )

      assert result.layout == :urgent
      assert result.layout_from == :brand
    end

    test "a channel that names no layout has none, in every form" do
      for input <- [
            %AshDispatch.Dsl.Channel{transport: :email, audience: :user},
            %{transport: :email, audience: :user},
            [transport: :email, audience: :user]
          ] do
        result = ChannelResolver.to_channel_struct(input)

        assert result.layout == nil
        assert result.layout_from == nil
      end
    end
  end

  describe "Dispatcher.resolve_channel_layout/2" do
    test "the channel's own layout wins, as a string" do
      channel = %Channel{transport: :email, audience: :user, layout: :urgent}

      assert Dispatcher.resolve_channel_layout(channel, ctx()) == "urgent"
    end

    test "layout_from reads the field off the event's record" do
      channel = %Channel{transport: :email, audience: :user, layout_from: :brand}

      assert Dispatcher.resolve_channel_layout(channel, ctx(%{record: %{brand: "northwind"}})) ==
               "northwind"
    end

    test "a static layout wins over layout_from" do
      channel = %Channel{
        transport: :email,
        audience: :user,
        layout: "urgent",
        layout_from: :brand
      }

      assert Dispatcher.resolve_channel_layout(channel, ctx(%{record: %{brand: "northwind"}})) ==
               "urgent"
    end

    test "no layout at all is nil — the transport's default layout, as before" do
      channel = %Channel{transport: :email, audience: :user}

      assert Dispatcher.resolve_channel_layout(channel, ctx()) == nil
    end

    test "a layout_from whose field is missing or empty falls back to the default" do
      channel = %Channel{transport: :email, audience: :user, layout_from: :brand}

      assert Dispatcher.resolve_channel_layout(channel, ctx(%{record: %{}})) == nil
      assert Dispatcher.resolve_channel_layout(channel, ctx(%{record: %{brand: nil}})) == nil
      assert Dispatcher.resolve_channel_layout(channel, ctx(%{record: %{brand: ""}})) == nil
    end

    # The name becomes a path segment under priv/ash_dispatch/layouts/, and
    # `layout_from` reads a column the library has never seen. A row holding
    # "../../../../etc/passwd" must not pick the file it names.
    test "a name that is not a name is refused, not joined into a path" do
      channel = %Channel{transport: :email, audience: :user, layout_from: :brand}

      for bad <- [
            "../../../etc",
            "..",
            ".",
            "a/b",
            "/absolute",
            "with space",
            "semi;colon",
            "null\0byte"
          ] do
        assert Dispatcher.resolve_channel_layout(channel, ctx(%{record: %{brand: bad}})) == nil,
               "#{inspect(bad)} was accepted as a layout name"
      end
    end

    test "a static layout is checked too, not only the dynamic one" do
      channel = %Channel{transport: :email, audience: :user, layout: "../escape"}

      assert Dispatcher.resolve_channel_layout(channel, ctx()) == nil
    end

    test "the names a brand edition actually uses are accepted" do
      channel = %Channel{transport: :email, audience: :user, layout_from: :brand}

      for good <- ["northwind", "north-wind", "north_wind", "v2.1", "Brand9"] do
        assert Dispatcher.resolve_channel_layout(channel, ctx(%{record: %{brand: good}})) == good
      end
    end
  end

  describe "the template resolver renders through the named layout" do
    @layout_dir "urgent"

    setup do
      priv = :code.priv_dir(:ash_dispatch) |> to_string()
      layouts = Path.join(priv, "ash_dispatch/layouts")
      templates = Path.join(priv, "ash_dispatch/templates")
      File.mkdir_p!(Path.join(layouts, @layout_dir))
      File.mkdir_p!(templates)

      default = Path.join(layouts, "email.text.eex")
      named = Path.join([layouts, @layout_dir, "email.text.eex"])
      html_default = Path.join(layouts, "email.html.heex")

      File.write!(default, "DEFAULT[<%= @inner_content %>]")
      File.write!(named, "URGENT[<%= @inner_content %>]")
      File.write!(html_default, "DEFAULT-HTML[<%= @inner_content %>]")

      on_exit(fn ->
        File.rm(default)
        File.rm(named)
        File.rm(html_default)
        File.rmdir(Path.join(layouts, @layout_dir))
      end)

      {:ok, dir: Path.join(priv, "ash_dispatch/channel_layout_test")}
    end

    defp template_dir!(dir, body) do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "email.text.eex"), body)
      on_exit(fn -> File.rm_rf(dir) end)
      dir
    end

    defp render(dir, opts) do
      TemplateResolver.render(
        [
          template_path: dir,
          otp_app: :ash_dispatch,
          format: :text,
          transport: :email,
          assigns: %{}
        ] ++ opts
      )
    end

    test "without a layout: the default layout wraps it, as it always did", %{dir: dir} do
      dir = template_dir!(dir, "body")

      assert {:ok, "DEFAULT[body]"} = render(dir, [])
      assert {:ok, "DEFAULT[body]"} = render(dir, layout: nil)
    end

    test "with a layout: the named one wraps it", %{dir: dir} do
      dir = template_dir!(dir, "body")

      assert {:ok, "URGENT[body]"} = render(dir, layout: @layout_dir)
      assert {:ok, "URGENT[body]"} = render(dir, layout: :urgent)
    end

    test "a named layout with no file for this format falls back on the default", %{dir: dir} do
      dir = template_dir!(dir, "body")

      # `layouts/html_only/` exists and holds no TEXT layout, so the text
      # render takes the default one rather than going unwrapped.
      priv = :code.priv_dir(:ash_dispatch) |> to_string()
      subdir = Path.join(priv, "ash_dispatch/layouts/html_only")
      File.mkdir_p!(subdir)
      File.write!(Path.join(subdir, "email.html.heex"), "HTML-ONLY[<%= @inner_content %>]")
      on_exit(fn -> File.rm_rf(subdir) end)

      assert {:ok, "DEFAULT[body]"} = render(dir, layout: "html_only")
    end

    test "a transport with no layout at all leaves the content unwrapped", %{dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "sms.text.eex"), "body")
      on_exit(fn -> File.rm_rf(dir) end)

      # Nothing under layouts/ answers for :sms, named or default.
      assert {:ok, "body"} =
               TemplateResolver.render(
                 template_path: dir,
                 otp_app: :ash_dispatch,
                 format: :text,
                 transport: :sms,
                 layout: @layout_dir,
                 assigns: %{}
               )
    end

    test "a layout named by a path is refused by the resolver too", %{dir: dir} do
      dir = template_dir!(dir, "body")

      # Not the layout it names, and not an error either: the default.
      assert {:ok, "DEFAULT[body]"} = render(dir, layout: "../../../etc")
    end
  end
end
