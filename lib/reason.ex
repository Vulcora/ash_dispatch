defmodule AshDispatch.Reason do
  @moduledoc """
  Why a receipt was not sent, as a closed code beside the sentence a person
  reads.

  `error_message` is written for a human: "Recipient 3f2a… opted out of
  \"orders.created\" via :email, skipping". It is the right thing to show on a
  receipt and the wrong thing to count, so every host that wanted "how many
  letters did we hold back last month, and why" matched substrings against
  sentences this library is free to reword. Three of them did, independently.

  Since 0.9.4 the library also writes a code: `content["reason_code"]`, one of
  `codes/0`, with `:other` for a reason that came from somewhere else — a
  backend of the host's own, a provider's message, a transport the host wrote.
  The sentence is unchanged and still says more than the code does.

  ## Reading it

      AshDispatch.Reason.of(receipt)
      #=> :user_opted_out

  `of/1` answers for a receipt written before 0.9.4 too, by classifying the
  sentence — which is the substring matching, done once, here, by the library
  that wrote the sentences. A host never needs to do it.

  ## Counting it

  The code is in `content`, so no migration and nothing to backfill. In SQL it
  is a JSONB lookup:

      SELECT content->>'reason_code' AS reason, count(*)
      FROM delivery_receipts
      WHERE status IN ('skipped', 'failed_permanent')
      GROUP BY 1 ORDER BY 2 DESC;

  Rows written before 0.9.4 answer `NULL` there; `of/1` still classifies them.

  ## The codes

  | Code | What held the letter back |
  |---|---|
  | `:event_gate_closed` | the event's own gate said no (`AshDispatch.Gate`) |
  | `:recipient_ineligible` | the host's eligibility check said no (`AshDispatch.EligibleRecipient`) |
  | `:user_opted_out` | the recipient's preferences (`AshDispatch.Transports.Preferences`) |
  | `:skip_if_read` | the linked in-app notification had been read |
  | `:delivery_blocked` | `delivery_mode: :blocked`, or `skip_email_delivery: true` |
  | `:delivery_dry_run` | `delivery_mode: :dry_run` |
  | `:delivery_not_allowed` | an allow-list the recipient is not on |
  | `:backend_not_configured` | no backend configured for the transport |
  | `:backend_skipped` | the backend answered `{:skip, reason}` |
  | `:transport_not_implemented` | the transport has no backend in this release |
  | `:transport_unknown` | a channel named a transport nothing is registered for |
  | `:webhook_url_missing` | no `webhook_url`, or its env var is unset |
  | `:no_pubsub_module` | `:broadcast` with no PubSub configured |
  | `:no_user_id` | the receipt names nobody to broadcast to |
  | `:throttled` | a broadcast dropped by the throttle |
  | `:content_scrubbed` | the body had been scrubbed; never sent as the marker |
  | `:no_body` | nothing left to send, so it failed closed |
  | `:stranded` | closed or returned by the stranded sweep |
  | `:enqueue_failed` | the retry's own job could not be enqueued |
  | `:other` | anything the library did not write |

  The list is closed on purpose: a code that means "some other thing" is worth
  nothing to count, so a new reason gets a new code in a new release rather
  than being folded into `:other`.
  """

  alias AshDispatch.ContentMap

  @content_key "reason_code"

  @codes [
    :event_gate_closed,
    :recipient_ineligible,
    :user_opted_out,
    :skip_if_read,
    :delivery_blocked,
    :delivery_dry_run,
    :delivery_not_allowed,
    :backend_not_configured,
    :backend_skipped,
    :transport_not_implemented,
    :transport_unknown,
    :webhook_url_missing,
    :no_pubsub_module,
    :no_user_id,
    :throttled,
    :content_scrubbed,
    :no_body,
    :stranded,
    :enqueue_failed,
    :other
  ]

  @typedoc "One of `codes/0`."
  @type code :: atom()

  # Each entry is {what the sentence starts with, the code}. The library writes
  # every one of these, several with detail appended, so the stem is matched
  # rather than the whole sentence. Longest stem first where two share a
  # prefix, so the more specific one wins.
  @stems [
    {"event_gate_closed", :event_gate_closed},
    {"recipient_ineligible", :recipient_ineligible},
    {"user_opted_out", :user_opted_out},
    {"Recipient ", :user_opted_out},
    {"User opted out of this email category", :user_opted_out},
    {"notification already read", :skip_if_read},
    {"delivery_blocked", :delivery_blocked},
    {"email delivery disabled", :delivery_blocked},
    {"delivery_dry_run", :delivery_dry_run},
    {"delivery_not_allowed", :delivery_not_allowed},
    {"no email_backend configured", :backend_not_configured},
    {"backend did not send", :backend_skipped},
    {"transport_not_implemented", :transport_not_implemented},
    {"Unknown transport", :transport_unknown},
    {"No webhook_url configured", :webhook_url_missing},
    {"webhook_url_env ", :webhook_url_missing},
    {"no_pubsub_module", :no_pubsub_module},
    {"no_user_id", :no_user_id},
    {"throttled", :throttled},
    {"the content was scrubbed from the receipt", :content_scrubbed},
    {"sensitive content already scrubbed from the receipt", :content_scrubbed},
    {"sensitive event's receipt has no body", :no_body},
    {"sensitive event's receipt has no text", :no_body},
    {"the job carries no body", :no_body},
    {"Stranded in ", :stranded},
    {"Failed to enqueue retry", :enqueue_failed}
  ]

  @doc """
  Every code the library writes, `:other` included.
  """
  @spec codes() :: [code()]
  def codes, do: @codes

  @doc """
  Whether `code` is one of `codes/0`.
  """
  @spec code?(term()) :: boolean()
  def code?(code), do: code in @codes

  @doc """
  The key the code is stored under in a receipt's `content`.

  Public so a host can name it in a SQL query without hard-coding the string
  in two places.
  """
  @spec content_key() :: String.t()
  def content_key, do: @content_key

  @doc """
  The code for one of the library's own reason sentences, or `:other`.

  `nil` and `""` are `nil`: nothing held the letter back.

      iex> AshDispatch.Reason.classify("delivery_dry_run")
      :delivery_dry_run

      iex> AshDispatch.Reason.classify("the provider refused: 550 mailbox full")
      :other

      iex> AshDispatch.Reason.classify(nil)
      nil
  """
  @spec classify(term()) :: code() | nil
  def classify(nil), do: nil
  def classify(""), do: nil

  def classify(message) when is_binary(message) do
    Enum.find_value(@stems, :other, fn {stem, code} ->
      if String.starts_with?(message, stem), do: code
    end)
  end

  def classify(message) when is_atom(message) do
    if code?(message), do: message, else: :other
  end

  def classify(_), do: :other

  @doc """
  The code on a receipt: the one stored in `content`, else classified from the
  sentence, else `nil` when nothing held this letter back.

  The fallback is what makes a receipt written before 0.9.4 answerable, so a
  host can count without a backfill and without matching sentences itself.
  """
  @spec of(map()) :: code() | nil
  def of(receipt) when is_map(receipt) do
    case stored(receipt) do
      nil -> classify(Map.get(receipt, :error_message))
      code -> code
    end
  end

  def of(_), do: nil

  @doc false
  # Writes the code for `message` into `content`, under both spellings removed
  # first so the map never carries the key twice — the same care
  # `AshDispatch.Changes.PutDigest` takes, and for the same reason.
  @spec put(map(), term()) :: map()
  def put(content, message) do
    content = content || %{}

    case classify(message) do
      nil ->
        content

      code ->
        content
        |> Map.delete(:reason_code)
        |> Map.delete(@content_key)
        |> Map.put(@content_key, Atom.to_string(code))
    end
  end

  defp stored(receipt) do
    case ContentMap.get_content(Map.get(receipt, :content), :reason_code) do
      value when is_binary(value) and value != "" -> to_code(value)
      value when is_atom(value) and not is_nil(value) -> if code?(value), do: value, else: :other
      _ -> nil
    end
  end

  # Never `String.to_atom/1` on a value read back from a JSONB column: the
  # closed list is the whole point, and an unknown string is `:other`.
  defp to_code(value) do
    Enum.find(@codes, :other, &(Atom.to_string(&1) == value))
  end
end
