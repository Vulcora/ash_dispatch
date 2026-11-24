defmodule AshDispatch.Transports.EmailContentStringKeysTest do
  # Async disabled: reads Application config for event discovery, same as
  # EmailSensitiveArgsTest.
  use ExUnit.Case, async: false

  alias AshDispatch.Channel
  alias AshDispatch.Config
  alias AshDispatch.Context
  alias AshDispatch.Transports.Email
  alias AshDispatch.Workers.SendEmail

  @moduletag :capture_log

  setup do
    original = Application.get_env(:ash_dispatch, :otp_app)
    Application.put_env(:ash_dispatch, :otp_app, :ash_dispatch_test)

    on_exit(fn ->
      if original,
        do: Application.put_env(:ash_dispatch, :otp_app, original),
        else: Application.delete_env(:ash_dispatch, :otp_app)
    end)

    :ok
  end

  # A receipt as Postgres hands it back: `content` is a JSONB column, so every
  # key in it is a string however the dispatcher wrote it.
  defp reloaded_receipt(content) do
    %{
      id: Ecto.UUID.generate(),
      recipient: "user@example.com",
      subject: "Order created",
      body_html: "<h1>Order</h1>",
      body_text: "Order created",
      content: content
    }
  end

  defp args(receipt) do
    receipt
    |> Email.job_args(
      %Context{event_id: "ticket.created"},
      %Channel{transport: :email, audience: :user}
    )
    |> Jason.encode!()
    |> Jason.decode!()
  end

  describe "the sender of a receipt read back from JSONB" do
    test "a bare address under a string key is the job's sender, not the default" do
      args = args(reloaded_receipt(%{"from" => "orders@example.com"}))

      assert args["from"] == "orders@example.com"
      refute args["from"] == Config.default_from_email()
    end

    test "a name/email map under a string key is the job's sender" do
      receipt =
        reloaded_receipt(%{"from" => %{"name" => "Orders", "email" => "orders@example.com"}})

      assert args(receipt)["from"] == %{"name" => "Orders", "email" => "orders@example.com"}
    end

    test "the sender reaches the backend, not only the args" do
      receipt =
        reloaded_receipt(%{"from" => %{"name" => "Orders", "email" => "orders@example.com"}})

      params = SendEmail.email_params(receipt, args(receipt))

      assert params.from == {"Orders", "orders@example.com"}
    end

    test "a receipt with no sender of its own still falls back to the default" do
      args = args(reloaded_receipt(%{"subject" => "Order created"}))

      assert args["from"] == %{
               "name" => Config.default_from_name(),
               "email" => Config.default_from_email()
             }
    end

    test "the reply address under a string key survives too" do
      receipt =
        reloaded_receipt(%{"from" => "orders@example.com", "reply_to" => "help@example.com"})

      assert args(receipt)["reply_to"] == "help@example.com"
    end

    test "declared headers under a string key survive too" do
      receipt =
        reloaded_receipt(%{
          "from" => "orders@example.com",
          "headers" => %{"X-Order" => "1234"}
        })

      assert args(receipt)["headers"] == %{"X-Order" => "1234"}
    end
  end

  describe "an in-memory receipt, whose content still has atom keys" do
    test "a bare address is the job's sender" do
      assert args(reloaded_receipt(%{from: "orders@example.com"}))["from"] ==
               "orders@example.com"
    end

    test "a name/email map is the job's sender" do
      receipt = reloaded_receipt(%{from: %{"name" => "Orders", "email" => "orders@example.com"}})

      assert args(receipt)["from"] == %{"name" => "Orders", "email" => "orders@example.com"}
    end

    test "a {name, address} tuple becomes a name/email map for the args" do
      receipt = reloaded_receipt(%{from: {"Orders", "orders@example.com"}})

      assert args(receipt)["from"] == %{"name" => "Orders", "email" => "orders@example.com"}
    end
  end
end
