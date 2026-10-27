defmodule AshDispatch.HeadersTest do
  @moduledoc """
  The `headers/2` callback — extra headers such as `X-Entity-Ref-ID` — from
  the event, through the receipt and the `SendEmail` job, to Swoosh.
  """
  use ExUnit.Case, async: false

  import Swoosh.TestAssertions

  alias AshDispatch.EventResolver
  alias AshDispatch.Workers.SendEmail

  defmodule Event do
    @moduledoc false
    use AshDispatch.Event

    @impl true
    def id, do: "headers.test"

    @impl true
    def headers(%{data: %{headers: headers}}, _channel), do: headers
  end

  defp headers(returned) do
    EventResolver.headers(
      Event,
      %AshDispatch.Context{data: %{headers: returned}},
      %AshDispatch.Channel{
        transport: :email,
        audience: :user
      }
    )
  end

  describe "EventResolver.headers/3" do
    test "string names and values pass" do
      assert headers(%{"X-Entity-Ref-ID" => "B-1"}) == %{"X-Entity-Ref-ID" => "B-1"}
    end

    test "an atom name is accepted as its string" do
      assert headers(%{"X-Priority": "1"}) == %{"X-Priority" => "1"}
    end

    test "anything that is not a string value is dropped, not raised on" do
      # An integer id is what the docs' own example would often pass.
      assert headers(%{"X-Count" => 1, "X-Ok" => "yes"}) == %{"X-Count" => "1", "X-Ok" => "yes"}
      assert headers(%{"X-Float" => 1.5, "X-Nil" => nil}) == %{}
      assert headers(:not_a_map) == %{}
    end

    test "a value with a line break is dropped (header injection)" do
      assert headers(%{"X-Ref" => "a\r\nBcc: evil@example.com"}) == %{}
    end

    test "the envelope's own headers cannot be set here" do
      assert headers(%{"To" => "x@example.com", "reply-to" => "y@example.com", "X-Ok" => "1"}) ==
               %{"X-Ok" => "1"}
    end

    test "an event without the callback has none" do
      defmodule Bare do
        @moduledoc false
        def id, do: "bare"
      end

      assert EventResolver.headers(Bare, %AshDispatch.Context{}, %AshDispatch.Channel{
               transport: :email,
               audience: :user
             }) == %{}
    end
  end

  describe "SendEmail" do
    # A receipt as the worker reads one.
    defp receipt(content) do
      %{
        content: content,
        recipient: "a@example.com",
        subject: "s",
        body_html: nil,
        body_text: nil
      }
    end

    test "the job's headers reach the backend params" do
      params =
        SendEmail.email_params(receipt(%{}), %{"headers" => %{"X-Entity-Ref-ID" => "B-1"}})

      assert params.headers == %{"X-Entity-Ref-ID" => "B-1"}
    end

    test "a retry, which has no content args, reads them from the receipt" do
      params = SendEmail.email_params(receipt(%{"headers" => %{"X-Entity-Ref-ID" => "B-2"}}), %{})

      assert params.headers == %{"X-Entity-Ref-ID" => "B-2"}
    end

    test "without headers the params are exactly what they were before 0.9.0" do
      params = SendEmail.email_params(receipt(%{}), %{})
      refute Map.has_key?(params, :headers)
    end

    test "a retry keeps the sender from the receipt (JSONB string keys)" do
      params =
        SendEmail.email_params(
          receipt(%{"from" => %{"name" => "Bookings", "email" => "b@example.com"}}),
          %{}
        )

      assert params.from == {"Bookings", "b@example.com"}
    end
  end

  describe "EmailBackend.Swoosh" do
    setup do
      previous = Application.get_env(:ash_dispatch, :swoosh_mailer)
      Application.put_env(:ash_dispatch, :swoosh_mailer, AshDispatch.Test.Mailer)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:ash_dispatch, :swoosh_mailer, previous),
          else: Application.delete_env(:ash_dispatch, :swoosh_mailer)
      end)
    end

    test "adds every header to the email" do
      assert {:ok, _} =
               AshDispatch.EmailBackend.Swoosh.send_email(%{
                 to: "a@example.com",
                 from: "b@example.com",
                 subject: "Hello",
                 html_body: "<p>Hi</p>",
                 text_body: "Hi",
                 headers: %{"X-Entity-Ref-ID" => "B-3"}
               })

      assert_email_sent(fn email ->
        assert email.headers == %{"X-Entity-Ref-ID" => "B-3"}
      end)
    end
  end
end
