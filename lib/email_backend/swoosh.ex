defmodule AshDispatch.EmailBackend.Swoosh do
  @moduledoc """
  Swoosh-based email backend for AshDispatch.

  Uses a configured Swoosh mailer to send emails. This is the production-ready
  email backend that integrates with any Swoosh adapter (Resend, SendGrid,
  Postmark, SMTP, etc.).

  ## Configuration

  Configure in your application's config:

      # config/config.exs
      config :ash_dispatch,
        email_backend: AshDispatch.EmailBackend.Swoosh,
        swoosh_mailer: MyApp.Mailer

  Your Swoosh mailer should be configured separately:

      # config/config.exs
      config :my_app, MyApp.Mailer,
        adapter: Swoosh.Adapters.Resend,
        api_key: System.get_env("RESEND_API_KEY")

  ## Testing

  In tests, use Swoosh's test adapter:

      # config/test.exs
      config :my_app, MyApp.Mailer,
        adapter: Swoosh.Adapters.Test

  Then use Swoosh.TestAssertions in your tests:

      import Swoosh.TestAssertions

      assert_email_sent(
        to: "user@example.com",
        subject: "Welcome!"
      )

  ## Return Value

  Returns `{:ok, metadata}` on success with:
  - `:id` - Message ID from provider (if available)
  - `:provider` - Always `:swoosh`

  Returns `{:error, reason}` on failure.

  ## Example

      AshDispatch.EmailBackend.Swoosh.send_email(%{
        to: "user@example.com",
        from: "orders@myapp.com",
        subject: "Order Confirmation",
        html_body: "<h1>Thank you!</h1>",
        text_body: "Thank you!"
      })
      # => {:ok, %{id: "msg_xyz", provider: :swoosh}}
  """

  alias AshDispatch.Config

  require Logger

  @doc """
  Sends an email via Swoosh.

  ## Parameters

  - `params` - Map with:
    - `:to` - Recipient email address (string)
    - `:from` - Sender email address (string)
    - `:subject` - Email subject (string)
    - `:html_body` - HTML email body (string)
    - `:text_body` - Plain text email body (string)

  ## Returns

  - `{:ok, %{id: message_id, provider: :swoosh}}` on success
  - `{:error, reason}` on failure

  ## Examples

      iex> send_email(%{
      ...>   to: "user@example.com",
      ...>   from: "app@example.com",
      ...>   subject: "Hello",
      ...>   html_body: "<p>Hi there</p>",
      ...>   text_body: "Hi there"
      ...> })
      {:ok, %{id: "msg_123", provider: :swoosh}}
  """
  @spec send_email(map()) :: {:ok, map()} | {:error, any()}
  def send_email(%{to: to, from: from, subject: subject, html_body: html, text_body: text}) do
    import Swoosh.Email

    # Get configured mailer module
    mailer = get_mailer()

    Logger.debug("""
    Sending email via Swoosh:
      Mailer: #{inspect(mailer)}
      To: #{to}
      From: #{from}
      Subject: #{subject}
    """)

    # Build Swoosh email
    email =
      new()
      |> to(to)
      |> from(from)
      |> subject(subject)
      |> html_body(html)
      |> text_body(text)

    # Send via mailer
    case mailer.deliver(email) do
      {:ok, metadata} ->
        message_id = extract_message_id(metadata)

        Logger.info("""
        Email sent successfully via Swoosh
          Message ID: #{message_id}
          To: #{to}
          Subject: #{subject}
        """)

        {:ok, %{id: message_id, provider: :swoosh}}

      {:error, reason} ->
        Logger.error("""
        Failed to send email via Swoosh
          To: #{to}
          Subject: #{subject}
          Error: #{inspect(reason)}
        """)

        {:error, reason}
    end
  rescue
    error ->
      Logger.error("""
      Exception while sending email via Swoosh
        To: #{to}
        Subject: #{subject}
        Error: #{inspect(error)}
      """)

      {:error, error}
  end

  # Private functions

  defp get_mailer do
    case Config.swoosh_mailer() do
      nil ->
        raise """
        No Swoosh mailer configured for AshDispatch!

        Add to your config/config.exs:

          config :ash_dispatch,
            email_backend: AshDispatch.EmailBackend.Swoosh,
            swoosh_mailer: MyApp.Mailer

        Then configure your Swoosh mailer:

          config :my_app, MyApp.Mailer,
            adapter: Swoosh.Adapters.Resend,
            api_key: System.get_env("RESEND_API_KEY")
        """

      mailer ->
        mailer
    end
  end

  defp extract_message_id(%{id: id}), do: id
  defp extract_message_id(%{"id" => id}), do: id
  defp extract_message_id(_metadata), do: "unknown"
end
