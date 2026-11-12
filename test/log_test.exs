defmodule AshDispatch.LogTest do
  # Async disabled: changes :ash_dispatch application env
  use ExUnit.Case, async: false

  alias AshDispatch.Log

  setup do
    saved = Application.get_env(:ash_dispatch, :log_recipients)

    on_exit(fn ->
      if is_nil(saved),
        do: Application.delete_env(:ash_dispatch, :log_recipients),
        else: Application.put_env(:ash_dispatch, :log_recipients, saved)
    end)

    Application.delete_env(:ash_dispatch, :log_recipients)
    :ok
  end

  describe "by default a recipient is masked" do
    test "an address keeps its first letter and its domain" do
      assert Log.recipient("anna.andersson@example.com") == "a***@example.com"
    end

    test "a name and address pair, and a list, are masked the same way" do
      assert Log.recipient({"Anna Andersson", "anna@example.com"}) == "a***@example.com"

      assert Log.recipient(["anna@example.com", {"Bo", "bo@example.org"}]) ==
               "a***@example.com, b***@example.org"
    end

    test "a phone number keeps its last four digits" do
      assert Log.recipient("+46 70 123 45 67") == "***4567"
      assert Log.recipient("0701234567") == "***4567"
    end

    test "a map or struct is read for its address and never printed whole" do
      assert Log.recipient(%{email: "anna@example.com", name: "Anna Andersson", id: 7}) ==
               "a***@example.com"

      assert Log.recipient(%{name: "Anna Andersson"}) == "[recipient]"
      assert Log.recipient(nil) == "[recipient]"
    end

    test "the name never appears" do
      refute Log.recipient({"Anna Andersson", "anna@example.com"}) =~ "Andersson"
    end
  end

  describe "an error that quotes the address back" do
    test "has the address masked inside it" do
      reason =
        {:error,
         %{
           message: "550 mailbox anna.andersson@example.com unavailable",
           to: "anna.andersson@example.com"
         }}

      text = Log.reason(reason)
      refute text =~ "anna.andersson"
      assert text =~ "a***@example.com"
      assert text =~ "550 mailbox"
    end

    test "leaves ids, status codes and timestamps alone" do
      text =
        Log.reason(%{
          status: 422,
          id: "0b6c0a3e-7a0f-4f4e-9d0e-0f3f6a1c2b11",
          at: "2027-03-01T09:00:00Z"
        })

      assert text =~ "422"
      assert text =~ "0b6c0a3e-7a0f-4f4e-9d0e-0f3f6a1c2b11"
      assert text =~ "2027-03-01T09:00:00Z"
    end
  end

  describe "the setting" do
    test ":full writes the recipient as it is" do
      Application.put_env(:ash_dispatch, :log_recipients, :full)
      assert Log.recipient("anna@example.com") == "anna@example.com"
      assert Log.reason("to anna@example.com") == "to anna@example.com"
    end

    test ":none writes no part of it" do
      Application.put_env(:ash_dispatch, :log_recipients, :none)
      assert Log.recipient("anna@example.com") == "[recipient]"
      assert Log.reason("to anna@example.com failed") == "to [recipient] failed"
    end
  end

  describe "the library's own log lines" do
    test "no file writes a recipient, a subject or a webhook payload straight into a log line" do
      offenders =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.reject(&(&1 == "lib/log.ex"))
        |> Enum.filter(fn path ->
          path
          |> File.read!()
          |> String.split("\n")
          |> Enum.any?(fn line ->
            line =~ ~r/Subject: \#\{|inspect\(params\)\}/ or
              (line =~ ~r/(To|Recipient): \#\{/ and not (line =~ "Log.recipient("))
          end)
        end)

      assert offenders == [],
             "these files log personal data directly; use AshDispatch.Log: #{inspect(offenders)}"
    end
  end
end
