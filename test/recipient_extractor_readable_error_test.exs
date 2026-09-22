defmodule AshDispatch.RecipientExtractorReadableErrorTest do
  @moduledoc """
  The error message must not be the thing that breaks.

  `raise_extraction_error/5` wrote `recipient.__struct__` directly. Audiences
  can resolve to PLAIN MAPS, and on one of those the dot access raised a
  KeyError **inside the error message**. The caller therefore saw
  `%KeyError{key: :__struct__}` rather than "this recipient has no email
  address" — the one line that could have explained the failure was the line
  that broke.

  Seen at a consumer on 2026-09-02: an order confirmation never went out, and
  the log named neither the recipient nor the field.
  """
  use ExUnit.Case, async: true

  alias AshDispatch.Event.RecipientExtractor

  setup do
    tidigare = Application.get_env(:ash_dispatch, :recipient_fields)

    Application.put_env(:ash_dispatch, :recipient_fields, email: [identifier: :email])

    on_exit(fn ->
      if tidigare,
        do: Application.put_env(:ash_dispatch, :recipient_fields, tidigare),
        else: Application.delete_env(:ash_dispatch, :recipient_fields)
    end)

    :ok
  end

  test "a recipient that is a plain map gives a READABLE error, not KeyError" do
    mottagare = %{id: "abc", email: nil, display_name: "Kedjan"}

    fel =
      assert_raise RuntimeError, fn ->
        RecipientExtractor.extract_identifier(mottagare, :email, :user)
      end

    meddelande = Exception.message(fel)

    # What is actually needed to understand the failure: which field, which
    # transport, och vad mottagaren hade.
    assert meddelande =~ ":email"
    assert meddelande =~ "email transport"
    assert meddelande =~ "Available keys"
    refute meddelande =~ "KeyError"
  end

  test "och en struct beskrivs fortfarande med sitt namn" do
    fel =
      assert_raise RuntimeError, fn ->
        RecipientExtractor.extract_identifier(%URI{}, :email, :user)
      end

    assert Exception.message(fel) =~ "URI"
  end
end
