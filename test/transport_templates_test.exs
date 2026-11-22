defmodule AshDispatch.TransportTemplatesTest do
  @moduledoc """
  Templates for transports that are not email.

  `TemplateResolver` has always built its candidate filenames from the
  transport and the format, so it could always have found `sms.text.eex`. The
  dispatcher only ever called it with `transport: :email`, so a host that
  wrote one had a file that rendered nothing and no way to tell. One host had
  two of them.

  The feature is one line of code and three ways to get it wrong, and the
  review of the first attempt found all three. They are what most of this file
  is about:

  1. **The `default.*` fallback.** The candidate list ends with
     `default.<ext>`, the documented "ultimate fallback" that until now only
     email could reach. A host's `default.text.eex` is its generic LETTER:
     read as an SMS it is several paid segments, and as an in-app
     notification it is an email in a bell menu.
  2. **Precedence.** A template must fill a body the host never wrote and
     never override one it did, or a host that upgrades and changes nothing
     gets a different SMS — which a patch may not do.
  3. **Host code on a new path.** `prepare_template_assigns/2` must not run
     for a channel that has no template, because before this release it never
     did.
  """
  use AshDispatch.Test.PreviewCase, async: false

  alias AshDispatch.Preview

  @moduletag :capture_log

  defp letters(event_id, opts \\ []) do
    {:ok, letters} =
      Preview.render(
        event_id,
        :sample,
        [seed: 0, resolve_recipients?: false, read_records?: false] ++ opts
      )

    letters
  end

  defp content(letter, key), do: AshDispatch.ContentMap.get_content(letter.content, key)

  describe "a transport template fills a body the host never wrote" do
    test "sms renders sms.text.eex" do
      [sms] = letters("booking.untexted", transport: :sms)

      assert content(sms, :message) =~ "Booking B-UNTEXTED is tomorrow."
    end

    test "and the message is what the transport will actually read" do
      # `Transports.SMS` and the e-lks backend read `content[:message]`.
      [sms] = letters("booking.untexted", transport: :sms)

      assert sms.message =~ "Booking B-UNTEXTED is tomorrow."
    end

    test "a transport with no template of its own keeps the placeholder" do
      # No `in_app.text.eex` in that directory — and `default.text.eex` IS
      # there, which is the whole point.
      [in_app] = letters("booking.untexted", transport: :in_app)

      assert content(in_app, :message) == "You have a new notification"
    end
  end

  describe "the default.* fallback is never reached by a non-email body" do
    test "not for in_app, which would show a whole email in a bell menu" do
      [in_app] = letters("booking.untexted", transport: :in_app)

      refute content(in_app, :message) =~ "GENERIC LETTER"
    end

    test "not for sms, where it would be several paid segments" do
      [sms] = letters("booking.untexted", transport: :sms)

      refute content(sms, :message) =~ "GENERIC LETTER"
    end

    test "not for a transport that has no branch of its own either" do
      [slack] = letters("booking.texted", transport: :slack)

      refute content(slack, :message) =~ "GENERIC LETTER"
    end

    test "but email still reaches it, exactly as it always has" do
      # `booking.untexted` has no `email.*` template, so email falls through
      # to `default.text.eex` — the behaviour the option exists to preserve.
      assert {:ok, rendered} =
               AshDispatch.TemplateResolver.render(
                 template_path: "test/support/preview/texted/templates",
                 otp_app: :ash_dispatch,
                 format: :text,
                 transport: :email,
                 assigns: %{reference: "B-X"}
               )

      assert rendered =~ "GENERIC LETTER"
    end

    test "and the builder itself keeps the fallback unless asked" do
      assert {:ok, _} =
               AshDispatch.TemplateResolver.render(
                 template_path: "test/support/preview/texted/templates",
                 otp_app: :ash_dispatch,
                 format: :text,
                 transport: :carrier_pigeon,
                 assigns: %{reference: "B-X"}
               )

      assert {:error, :template_not_found} =
               AshDispatch.TemplateResolver.render(
                 template_path: "test/support/preview/texted/templates",
                 otp_app: :ash_dispatch,
                 format: :text,
                 transport: :carrier_pigeon,
                 fallback?: false,
                 assigns: %{reference: "B-X"}
               )
    end
  end

  describe "precedence: a declared body wins over a template" do
    test "a module that overrides notification_message/2 keeps its own text" do
      # `booking.texted` has BOTH an sms.text.eex and an override. A host that
      # upgrades and changes nothing must get the text it already got.
      [sms] = letters("booking.texted", transport: :sms)

      assert content(sms, :message) == "Message from the callback"
      refute content(sms, :message) =~ "is tomorrow"
    end

    test "the same for slack" do
      [slack] = letters("booking.texted", transport: :slack)

      assert content(slack, :message) == "Message from the callback"
    end

    test "a title the host declared is untouched either way" do
      [in_app] = letters("booking.texted", transport: :in_app)

      assert content(in_app, :title) == "From the callback"
    end

    test "an inline-declared message wins too" do
      {:ok, letters} =
        Preview.render("booking.untexted", :sample,
          seed: 0,
          transport: :sms,
          resolve_recipients?: false,
          read_records?: false
        )

      # Baseline: nothing declared, so the template fills it.
      assert [sms] = letters
      assert content(sms, :message) =~ "is tomorrow"

      # And with a declared body, through the dispatcher's own content build.
      channel = %AshDispatch.Channel{
        transport: :sms,
        audience: :user,
        content: %{message: "Declared right here"}
      }

      context = %AshDispatch.Context{
        event_id: "booking.untexted",
        resource_key: :booking,
        data: AshDispatch.EventResolver.sample_data(AshDispatch.Test.Preview.BookingUntexted),
        variables: %{},
        metadata: %{}
      }

      {_status, attrs} =
        AshDispatch.Dispatcher.build_receipt(context, channel, %{}, nil)

      assert AshDispatch.ContentMap.get_content(attrs.content, :message) == "Declared right here"
    end
  end

  describe "host code is not called more than it was" do
    # `build_content/5` has always called `prepare_template_assigns/2` once per
    # channel, whatever the transport, to build the enhanced context — so the
    # callback is not new on this path. What WOULD be new is a second call, on
    # every dispatch of every non-email channel, just to discover there is no
    # template. The assigns are a function the resolver calls only after it has
    # found one, so the count is the assertion.
    defp calls(event_id) do
      Stream.repeatedly(fn ->
        receive do
          {:assigns_prepared, ^event_id} -> 1
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(&(&1 == 1))
      |> length()
    end

    test "a channel with no template of its own costs exactly one call" do
      letters("booking.untexted", transport: :in_app)

      assert calls("booking.untexted") == 1
    end

    test "and one WITH a template costs two, as email always has" do
      [sms] = letters("booking.untexted", transport: :sms)

      assert calls("booking.untexted") == 2
      assert content(sms, :message) =~ "B-UNTEXTED"
    end
  end

  describe "email is unchanged" do
    test "it still renders its own html and text, through its own path" do
      [email] = letters("booking.confirmed", transport: :email)

      assert email.html_body
      assert email.text_body
      assert email.subject
    end

    test "and a non-email template does not leak into the email body" do
      [email] = letters("booking.reminder", transport: :email, variant: nil)

      refute email.text_body =~ "is tomorrow"
    end
  end

  describe "the locale, variant and layout reach the non-email render" do
    test "the locale is set for the render and lands on the receipt" do
      [sms] = letters("booking.untexted", transport: :sms, locale: "sv")

      assert sms.locale == "sv"
      assert content(sms, :message) =~ "is tomorrow"
    end

    test "a locale-specific template is preferred where one exists" do
      [sms] = letters("booking.untexted", transport: :sms, locale: "no")

      # `sms.no.text.eex` is in the fixture directory.
      assert content(sms, :message) =~ "Booking B-UNTEXTED i morgen."
    end

    test "a variant-specific template is preferred where one exists" do
      # Through the resolver: `variant:` on `Preview.render/3` is a channel
      # FILTER, and these channels declare no variant.
      assert {:ok, rendered} =
               AshDispatch.TemplateResolver.render(
                 template_path: "test/support/preview/texted/templates",
                 otp_app: :ash_dispatch,
                 format: :text,
                 transport: :sms,
                 variant: "short",
                 fallback?: false,
                 assigns: %{reference: "B-X"}
               )

      assert rendered =~ "B-X tomorrow"
    end

    test "a layout wraps a non-email body when the host wrote one" do
      priv = :code.priv_dir(:ash_dispatch) |> to_string()
      dir = Path.join(priv, "ash_dispatch/layouts/sms_frame")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "sms.text.eex"), "FRAMED[<%= @inner_content %>]")
      on_exit(fn -> File.rm_rf(dir) end)

      assert {:ok, rendered} =
               AshDispatch.TemplateResolver.render(
                 template_path: "test/support/preview/texted/templates",
                 otp_app: :ash_dispatch,
                 format: :text,
                 transport: :sms,
                 layout: "sms_frame",
                 fallback?: false,
                 assigns: %{reference: "B-X"}
               )

      assert rendered =~ "FRAMED["
      assert rendered =~ "Booking B-X is tomorrow."
    end
  end

  describe "a text template is not HTML-escaped" do
    test "an ampersand in a text body stays an ampersand" do
      # `:text` goes out as plain `<%= @var %>`; only `:html` is wrapped in
      # `SafeRender.escape/1`. An SMS reading "Bed &amp; Breakfast" would be
      # the escaping of a format that has no markup.
      assert {:ok, rendered} =
               AshDispatch.TemplateResolver.render(
                 template_path: "test/support/preview/texted/templates",
                 otp_app: :ash_dispatch,
                 format: :text,
                 transport: :sms,
                 fallback?: false,
                 assigns: %{reference: "Bed & Breakfast <b>"}
               )

      assert rendered =~ "Bed & Breakfast <b>"
      refute rendered =~ "&amp;"
    end
  end

  describe "locale and variant cannot reach outside the templates directory" do
    defp candidate_render(opts) do
      AshDispatch.TemplateResolver.render(
        [
          template_path: "test/support/preview/texted/templates",
          otp_app: :ash_dispatch,
          format: :text,
          transport: :sms,
          fallback?: false,
          assigns: %{reference: "B-X"}
        ] ++ opts
      )
    end

    test "a locale that is a path is refused, and the base template answers" do
      # `locale_from:` reads an arbitrary record column, so the value can be
      # whatever a row holds — the same reason `layout` has a sanitiser.
      for bad <- ["../../../etc/passwd", "..", "a/b", "/abs", "with space"] do
        assert {:ok, rendered} = candidate_render(locale: bad),
               "#{inspect(bad)} broke the render instead of being dropped"

        assert rendered =~ "Booking B-X is tomorrow.", "#{inspect(bad)} selected something else"
      end
    end

    test "a variant that is a path is refused the same way" do
      for bad <- ["../../../etc/passwd", "..", "a/b"] do
        assert {:ok, rendered} = candidate_render(variant: bad)
        assert rendered =~ "Booking B-X is tomorrow."
      end
    end

    test "and a name that IS a name still selects its template" do
      assert {:ok, rendered} = candidate_render(locale: "no")
      assert rendered =~ "i morgen"
    end
  end
end
