defmodule AshDispatch.RecipientExtractorReadableErrorTest do
  @moduledoc """
  Felmeddelandet får inte vara det som går sönder.

  `raise_extraction_error/5` skrev `recipient.__struct__` rakt av. Målgrupper
  kan lösas till VANLIGA MAPPAR, och på en sådan kastade punktåtkomsten
  KeyError **inuti felmeddelandet**. Anroparen såg alltså
  `%KeyError{key: :__struct__}` i stället för "den här mottagaren saknar
  e-post" — den enda rad som kunde ha förklarat felet var raden som brast.

  Sett i magasin 2026-09-02: en orderbekräftelse gick aldrig ut, och loggen
  nämnde varken mottagare eller fält.
  """
  use ExUnit.Case, async: true

  alias AshDispatch.Event.RecipientExtractor

  setup do
    tidigare = Application.get_env(:ash_dispatch, :recipient_fields)

    Application.put_env(:ash_dispatch, :recipient_fields,
      email: [identifier: :email]
    )

    on_exit(fn ->
      if tidigare,
        do: Application.put_env(:ash_dispatch, :recipient_fields, tidigare),
        else: Application.delete_env(:ash_dispatch, :recipient_fields)
    end)

    :ok
  end

  test "en mottagare som är en vanlig map ger ett LÄSBART fel, inte KeyError" do
    mottagare = %{id: "abc", email: nil, display_name: "Kedjan"}

    fel =
      assert_raise RuntimeError, fn ->
        RecipientExtractor.extract_identifier(mottagare, :email, :user)
      end

    meddelande = Exception.message(fel)

    # Det som faktiskt behövs för att förstå felet: vilket fält, vilken
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
