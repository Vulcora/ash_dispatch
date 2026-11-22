defmodule AshDispatch.TransportTemplatesTest do
  @moduledoc """
  Templates for transports that are not email.

  `TemplateResolver` has always built its candidate filenames from the
  transport and the format, so it could always have found `sms.text.eex`.
  The dispatcher only ever called it with `transport: :email`, so a host that
  wrote one had a file that rendered nothing and no way to tell. One host had
  two of them.

  The two halves that matter: a template, where one exists, is the body; and
  an installation without one sees no difference at all.
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

  describe "a transport with a template of its own" do
    test "sms renders sms.text.eex as the message" do
      [sms] = letters("booking.texted", transport: :sms)

      assert content(sms, :message) =~ "Booking B-TEXTED is tomorrow."
      refute content(sms, :message) =~ "from the callback"
    end

    test "slack renders slack.text.eex" do
      [slack] = letters("booking.texted", transport: :slack)

      assert content(slack, :message) =~ "Slack: booking B-TEXTED is tomorrow."
    end

    test "the message is what the transport will actually read" do
      # `Transports.SMS` and the e-lks backend read `content[:message]`, so
      # the rendered text has to land there and nowhere else.
      [sms] = letters("booking.texted", transport: :sms)

      assert sms.message =~ "Booking B-TEXTED is tomorrow."
    end
  end

  describe "a transport without one" do
    test "falls back on the content callbacks, as it always did" do
      # Same event, same directory — there is no `in_app.text.eex` in it.
      [in_app] = letters("booking.texted", transport: :in_app)

      assert content(in_app, :message) == "Message from the callback"
      assert content(in_app, :title) == "From the callback"
    end

    test "an event with no templates at all is untouched" do
      [in_app] = letters("booking.reminder", transport: :in_app)

      assert content(in_app, :message) == "Reminder for B-SAMPLE"
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
    test "a locale-specific template is preferred where one exists" do
      # None here, so the base `sms.text.eex` answers — which is the fallback
      # chain the email path has always had, now reached by sms too.
      [sms] = letters("booking.texted", transport: :sms, locale: "sv")

      assert content(sms, :message) =~ "Booking B-TEXTED is tomorrow."
      assert sms.locale == "sv"
    end
  end
end
