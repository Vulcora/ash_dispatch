defmodule AshDispatch.DigestRenderer do
  @moduledoc """
  Renders a digest: several emails to one person, as one.

  `AshDispatch.Digest` hands the renderer the items in the order the emails
  were written, and gets back the letter:

      config :ash_dispatch, digest_renderer: MyApp.DigestRenderer

      defmodule MyApp.DigestRenderer do
        @behaviour AshDispatch.DigestRenderer

        @impl true
        def render(items, info) do
          %{
            subject: "\#{info.count} updates",
            html_body: MyAppWeb.Mail.digest_html(items),
            text_body: MyAppWeb.Mail.digest_text(items)
          }
        end
      end

  ## Items

  One map per email, with string keys: whatever the event's
  `c:AshDispatch.Event.digest_item/2` returned, over the defaults —

    * `"title"` — the email's subject,
    * `"summary"` — the first paragraph of its text body, or `nil`,
    * `"url"` — `nil`,

  plus, always, `"event_id"`, `"receipt_id"` and `"batched_at"` (a
  `DateTime`). Values are what the event put there: escape them for HTML.

  ## Info

  `%{recipient:, user_id:, locale:, count:}` — the address, the recipient's
  user id (or `nil`), the locale the first email was rendered in, and how
  many items there are.

  ## The letter

  `:subject` is required. `:html_body` and `:text_body` are what is sent;
  give both. `:from` and `:reply_to` are optional: without them the digest
  goes out with the first email's.

  A renderer that raises fails the flush, which Oban retries: the emails stay
  `:batched` and nothing is lost.
  """

  @typedoc "One email in the digest. See the module documentation."
  @type item :: %{optional(String.t()) => term()}

  @typedoc "Who the digest is for, and how many emails it holds."
  @type info :: %{
          recipient: String.t(),
          user_id: term(),
          locale: String.t() | nil,
          count: pos_integer()
        }

  @typedoc "The rendered digest."
  @type letter :: %{
          required(:subject) => String.t(),
          optional(:html_body) => String.t() | nil,
          optional(:text_body) => String.t() | nil,
          optional(:from) => term(),
          optional(:reply_to) => String.t() | nil
        }

  @callback render([item(), ...], info()) :: letter()
end
