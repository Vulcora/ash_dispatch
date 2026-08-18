defmodule AshDispatch.PreviewTest do
  @moduledoc """
  `AshDispatch.preview/3` — the documented facade over the ManualTrigger
  preview engine.

  The engine has always existed, but only behind a resource action, so an
  app that wanted to render a mail into an admin screen or a test either
  went through a ManualTrigger resource or reached into a `@moduledoc
  false` helper. The facade must stay a thin one: whatever the helper
  returns, `preview/3` returns.
  """
  # Async disabled: event discovery needs the test otp_app + domains.
  use ExUnit.Case, async: false

  alias AshDispatch.Resources.ManualTrigger.Helpers
  alias AshDispatch.Test.Order

  setup do
    previous_otp_app = Application.get_env(:ash_dispatch, :otp_app)
    previous_domains = Application.get_env(:ash_dispatch, :domains)

    Application.put_env(:ash_dispatch, :otp_app, :ash_dispatch_test)
    Application.put_env(:ash_dispatch, :domains, [AshDispatch.Test.Domain])

    on_exit(fn ->
      restore(:otp_app, previous_otp_app)
      restore(:domains, previous_domains)
    end)

    order =
      Order
      |> Ash.Changeset.for_create(:create, %{order_number: "SO-1234"})
      |> Ash.create!(authorize?: false)

    %{order: order}
  end

  defp restore(key, nil), do: Application.delete_env(:ash_dispatch, key)
  defp restore(key, value), do: Application.put_env(:ash_dispatch, key, value)

  describe "preview/3" do
    test "renders one map per channel of the event", %{order: order} do
      assert {:ok, [preview]} = AshDispatch.preview("order.created", %{order_id: order.id})

      assert preview.transport == :email
      assert preview.audience == :user
      assert preview.channel == %{transport: :email, audience: :user}
      assert Map.has_key?(preview, :subject)
      assert Map.has_key?(preview, :html_body)
      assert Map.has_key?(preview, :text_body)
      assert Map.has_key?(preview, :from_address)
      assert Map.has_key?(preview, :recipient)
    end

    test "returns exactly what the underlying helper returns", %{order: order} do
      context_data = %{order_id: order.id}

      assert AshDispatch.preview("order.created", context_data) ==
               Helpers.preview_trigger("order.created", context_data, nil, nil, nil)
    end

    test "context_data defaults to %{} (the event's sample data)" do
      assert AshDispatch.preview("order.created") ==
               Helpers.preview_trigger("order.created", %{}, nil, nil, nil)
    end

    test ":transport and :audience filter the channels", %{order: order} do
      context_data = %{order_id: order.id}

      assert {:ok, [_ | _]} =
               AshDispatch.preview("order.created", context_data,
                 transport: :email,
                 audience: :user
               )

      # order.created has no in_app channel — the filter is applied, not ignored
      assert {:ok, []} = AshDispatch.preview("order.created", context_data, transport: :in_app)
      assert {:ok, []} = AshDispatch.preview("order.created", context_data, audience: :admin)
    end

    test "the filters build the same channel filter the helper takes", %{order: order} do
      context_data = %{order_id: order.id}
      filter = Helpers.build_channel_filter(:user, :email)

      assert AshDispatch.preview("order.created", context_data,
               audience: :user,
               transport: :email
             ) ==
               Helpers.preview_trigger("order.created", context_data, filter, nil, nil)
    end

    test ":recipient_email overrides the displayed recipient", %{order: order} do
      assert {:ok, [preview]} =
               AshDispatch.preview("order.created", %{order_id: order.id},
                 recipient_email: "stefan@example.com"
               )

      assert preview.recipient == "stefan@example.com"
    end

    test "an unknown event errors instead of raising" do
      assert {:error, message} = AshDispatch.preview("no.such.event", %{})
      assert message =~ "no.such.event"

      assert AshDispatch.preview("no.such.event", %{}) ==
               Helpers.preview_trigger("no.such.event", %{}, nil, nil, nil)
    end

    test "an unloadable record errors instead of raising" do
      assert {:error, message} =
               AshDispatch.preview("order.created", %{
                 order_id: "00000000-0000-0000-0000-000000000000"
               })

      assert message =~ "Failed to load"
    end
  end
end
