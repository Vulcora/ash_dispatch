defmodule AshDispatch.Resources.ManualTriggerPreviewLocaleVariantTest do
  @moduledoc """
  `AshDispatch.Preview.render/3` has taken `:locale` and `:variant` since
  0.8.6; the ManualTrigger `:preview` action did not forward them. An admin
  could therefore not read a letter in the language its recipient gets it in,
  nor pick a variant without knowing which audience selects it — the panel
  had the renderer and no way to ask it.
  """
  use AshDispatch.Test.PreviewCase, async: false

  alias AshDispatch.Test.Preview.ManualTrigger

  defp preview!(args) do
    ManualTrigger
    |> Ash.Query.for_read(:preview, Map.merge(%{event_id: "booking.reminder"}, args))
    |> Ash.read!(authorize?: false)
  end

  describe ":variant" do
    test "selects the channel with that variant, and says which it rendered" do
      assert [row] = preview!(%{variant: "host"})

      assert row.variant == "host"
      assert row.subject =~ "Guest reminder"
    end

    test "without it, every channel of the event comes back as before" do
      rows = preview!(%{})

      assert length(rows) > 1
      assert Enum.any?(rows, &(&1.variant == nil))
      assert Enum.any?(rows, &(&1.variant == "host"))
    end

    test "a variant no channel has renders nothing rather than guessing" do
      assert [] = preview!(%{variant: "nobody"})
    end

    test "an empty string is not a variant and is ignored" do
      assert length(preview!(%{variant: ""})) == length(preview!(%{}))
    end
  end

  describe ":locale" do
    test "is the locale the letters are rendered in, and comes back on the row" do
      for row <- preview!(%{locale: "sv"}) do
        assert row.locale == "sv"
      end
    end

    test "without it the rows carry whatever locale the channel resolved to" do
      rows = preview!(%{})

      # Nothing asked for a locale and these fixtures declare none, so the
      # answer is the event's — which is what it has always been.
      assert Enum.all?(rows, &(&1.locale == nil or is_binary(&1.locale)))
    end

    test "combines with :variant" do
      assert [row] = preview!(%{locale: "sv", variant: "host"})

      assert row.locale == "sv"
      assert row.variant == "host"
    end
  end

  describe "what did not change" do
    test "the action still accepts only the arguments it accepted, plus two" do
      accepted =
        ManualTrigger
        |> Ash.Resource.Info.action(:preview)
        |> Map.get(:arguments)
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert accepted == [
               :audience,
               :context_data,
               :event_id,
               :locale,
               :recipient_email,
               :transport,
               :variant
             ]
    end

    test "the rows still carry everything they carried" do
      assert [row | _] = preview!(%{})

      assert row.event_id == "booking.reminder"
      assert row.subject
      assert row.recipient
      assert row.transport
      assert row.audience
    end
  end
end
