defmodule AshDispatch.SMSBackend.PhoneTest do
  use ExUnit.Case, async: true

  alias AshDispatch.SMSBackend.Phone

  describe "svenska format" do
    for {in_, ut} <- [
          {"0701234567", "+46701234567"},
          {"070-123 45 67", "+46701234567"},
          {"070 123 45 67", "+46701234567"},
          {"(070) 123-4567", "+46701234567"},
          {"0046701234567", "+46701234567"},
          {"0046 70-123 45 67", "+46701234567"},
          {"+46701234567", "+46701234567"},
          {"+46 70 123 45 67", "+46701234567"},
          {"08-123 456 78", "+46812345678"}
        ] do
      test "#{in_} → #{ut}" do
        assert Phone.to_e164(unquote(in_)) == {:ok, unquote(ut)}
      end
    end
  end

  describe "det som ska avvisas" do
    # De här väger tyngre än de positiva: ett nummer som släpps igenom fel
    # blir ett SMS som tyst går till ingen, och kvittot säger :sent.
    for in_ <- [
          "123",
          "08-12",
          "abc",
          "",
          "   ",
          "+",
          "+0701234567",
          "+4670123456789012345",
          "070123456789012345"
        ] do
      test "#{inspect(in_)} avvisas" do
        assert Phone.to_e164(unquote(in_)) == :error
      end
    end

    test "nil avvisas" do
      assert Phone.to_e164(nil) == :error
    end

    test "annat än en sträng avvisas" do
      assert Phone.to_e164(46_701_234_567) == :error
    end
  end

  describe "landskoden" do
    test "en inledande nolla blir den konfigurerade landskoden" do
      Application.put_env(:ash_dispatch, :default_country_code, "47")
      on_exit(fn -> Application.delete_env(:ash_dispatch, :default_country_code) end)

      assert Phone.to_e164("0701234567") == {:ok, "+47701234567"}
    end

    test "ett nummer som redan bär + rörs inte av landskoden" do
      Application.put_env(:ash_dispatch, :default_country_code, "47")
      on_exit(fn -> Application.delete_env(:ash_dispatch, :default_country_code) end)

      assert Phone.to_e164("+46701234567") == {:ok, "+46701234567"}
      assert Phone.to_e164("0046701234567") == {:ok, "+46701234567"}
    end
  end
end
