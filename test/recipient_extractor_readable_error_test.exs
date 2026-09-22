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
    previous = Application.get_env(:ash_dispatch, :recipient_fields)

    Application.put_env(:ash_dispatch, :recipient_fields, email: [identifier: :email])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ash_dispatch, :recipient_fields, previous),
        else: Application.delete_env(:ash_dispatch, :recipient_fields)
    end)

    :ok
  end

  test "a recipient that is a plain map gives a READABLE error, not KeyError" do
    recipient = %{id: "abc", email: nil, display_name: "Acme"}

    error =
      assert_raise RuntimeError, fn ->
        RecipientExtractor.extract_identifier(recipient, :email, :user)
      end

    message = Exception.message(error)

    # What is actually needed to understand the failure: which field, which
    # transport, and what the recipient had.
    assert message =~ ":email"
    assert message =~ "email transport"
    assert message =~ "Available keys"
    refute message =~ "KeyError"
  end

  test "and a struct is still described by its name" do
    error =
      assert_raise RuntimeError, fn ->
        RecipientExtractor.extract_identifier(%URI{}, :email, :user)
      end

    assert Exception.message(error) =~ "URI"
  end
end
