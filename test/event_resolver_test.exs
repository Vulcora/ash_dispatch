defmodule AshDispatch.EventResolverTest do
  use ExUnit.Case, async: true

  alias AshDispatch.{Channel, Context, EventResolver}

  describe "call_if_exported/4" do
    test "returns result when function exists" do
      defmodule WithDomain do
        def domain, do: :orders
      end

      assert EventResolver.call_if_exported(WithDomain, :domain, []) == :orders
    end

    test "returns default when function not exported" do
      defmodule NoDomain do
      end

      assert EventResolver.call_if_exported(NoDomain, :domain, [], default: :unknown) == :unknown
    end

    @tag :capture_log
    test "returns default when function raises" do
      defmodule RaisingDomain do
        def domain, do: raise("boom")
      end

      assert EventResolver.call_if_exported(RaisingDomain, :domain, [], default: :fallback) ==
               :fallback
    end

    test "handles functions with arguments" do
      defmodule WithSubject do
        def subject(_context, _channel), do: "Test Subject"
      end

      context = %Context{event_id: "test", data: %{}, metadata: %{}}
      channel = %Channel{transport: :email, audience: :user}

      assert EventResolver.call_if_exported(WithSubject, :subject, [context, channel]) ==
               "Test Subject"
    end
  end

  describe "reply_to/3" do
    test "returnerar modulens adress" do
      defmodule MedSvarsvag do
        def reply_to(_context, _channel), do: "saljaren@example.com"
      end

      assert EventResolver.reply_to(MedSvarsvag, ctx(), kanal()) == "saljaren@example.com"
    end

    test "a module without the callback gives nil — the behaviour before 0.8.1" do
      defmodule UtanSvarsvag do
      end

      assert EventResolver.reply_to(UtanSvarsvag, ctx(), kanal()) == nil
    end

    # This is the load-bearing half: an email that never leaves costs more than
    # ett mejl utan svarshuvud.
    test "junk is treated as nil rather than bringing the send down" do
      defmodule SkrapSvarsvag do
        def reply_to(_context, _channel), do: {"Namn", "a@b.se"}
      end

      defmodule TomSvarsvag do
        def reply_to(_context, _channel), do: ""
      end

      assert EventResolver.reply_to(SkrapSvarsvag, ctx(), kanal()) == nil
      assert EventResolver.reply_to(TomSvarsvag, ctx(), kanal()) == nil
    end

    @tag :capture_log
    test "en callback som kastar ger nil, inte ett kraschat utskick" do
      defmodule KastandeSvarsvag do
        def reply_to(_context, _channel), do: raise("boom")
      end

      assert EventResolver.reply_to(KastandeSvarsvag, ctx(), kanal()) == nil
    end

    defp ctx, do: %Context{event_id: "test", data: %{}, metadata: %{}}
    defp kanal, do: %Channel{transport: :email, audience: :customer}
  end

  describe "exports?/3" do
    test "returns true when function is exported" do
      defmodule ExportsTest do
        def sample_data, do: %{}
      end

      assert EventResolver.exports?(ExportsTest, :sample_data, 0)
    end

    test "returns false when function not exported" do
      defmodule NoExportsTest do
      end

      refute EventResolver.exports?(NoExportsTest, :sample_data, 0)
    end
  end

  describe "sample_data/1" do
    test "returns sample data from module" do
      defmodule WithSampleData do
        def sample_data, do: %{user: %{name: "Test"}}
      end

      assert EventResolver.sample_data(WithSampleData) == %{user: %{name: "Test"}}
    end

    test "returns empty map when not implemented" do
      defmodule NoSampleData do
      end

      assert EventResolver.sample_data(NoSampleData) == %{}
    end
  end

  describe "domain/1" do
    test "returns domain from module" do
      defmodule DomainModule do
        def domain, do: :accounts
      end

      assert EventResolver.domain(DomainModule) == :accounts
    end

    test "returns nil when not implemented" do
      defmodule NoDomainModule do
      end

      assert EventResolver.domain(NoDomainModule) == nil
    end
  end

  describe "build_sample_context/2" do
    test "builds context with sample data" do
      defmodule ContextModule do
        def sample_data, do: %{order: %{id: "123"}}
      end

      context = EventResolver.build_sample_context("orders.created", ContextModule)

      assert %Context{} = context
      assert context.event_id == "orders.created"
      assert context.data == %{order: %{id: "123"}}
    end
  end

  describe "subject/4" do
    test "returns subject from module" do
      defmodule SubjectModule do
        def subject(_context, _channel), do: "Order Created"
      end

      context = %Context{event_id: "test", data: %{}, metadata: %{}}
      channel = %Channel{transport: :email, audience: :user}

      assert EventResolver.subject(SubjectModule, context, channel) == "Order Created"
    end

    test "returns default when not implemented" do
      defmodule NoSubjectModule do
      end

      context = %Context{event_id: "test", data: %{}, metadata: %{}}
      channel = %Channel{transport: :email, audience: :user}

      assert EventResolver.subject(NoSubjectModule, context, channel, default: "Default") ==
               "Default"
    end
  end

  describe "from/3" do
    test "returns from tuple from module" do
      defmodule FromModule do
        def from(_context, _channel), do: {"Sender", "sender@example.com"}
      end

      context = %Context{event_id: "test", data: %{}, metadata: %{}}
      channel = %Channel{transport: :email, audience: :user}

      assert EventResolver.from(FromModule, context, channel) == {"Sender", "sender@example.com"}
    end
  end

  describe "user_configurable?/2" do
    test "returns true when module says so" do
      defmodule ConfigurableModule do
        def user_configurable?(_context), do: true
      end

      context = %Context{event_id: "test", data: %{}, metadata: %{}}

      assert EventResolver.user_configurable?(ConfigurableModule, context) == true
    end

    test "returns false by default" do
      defmodule NotConfigurableModule do
      end

      context = %Context{event_id: "test", data: %{}, metadata: %{}}

      assert EventResolver.user_configurable?(NotConfigurableModule, context) == false
    end
  end

  describe "applicable_for_user?/2" do
    test "returns result from module" do
      defmodule ApplicableModule do
        def applicable_for_user?(_user), do: false
      end

      assert EventResolver.applicable_for_user?(ApplicableModule, %{}) == false
    end

    test "returns true by default" do
      defmodule DefaultApplicableModule do
      end

      assert EventResolver.applicable_for_user?(DefaultApplicableModule, %{}) == true
    end
  end

  describe "generate_send_variables/3" do
    test "calls module callback when exported" do
      defmodule GenerateVarsModule do
        def generate_send_variables(_context, variables) do
          {:ok, Map.put(variables, :token, "abc123")}
        end
      end

      context = %Context{event_id: "test", data: %{}, metadata: %{}}

      assert {:ok, %{token: "abc123"}} =
               EventResolver.generate_send_variables(GenerateVarsModule, context, %{})
    end

    test "returns original variables when not exported" do
      defmodule NoGenerateVarsModule do
      end

      context = %Context{event_id: "test", data: %{}, metadata: %{}}
      variables = %{existing: "value"}

      assert {:ok, ^variables} =
               EventResolver.generate_send_variables(NoGenerateVarsModule, context, variables)
    end

    @tag :capture_log
    test "returns error when module raises" do
      defmodule RaisingGenerateVarsModule do
        def generate_send_variables(_context, _variables) do
          raise "Token generation failed"
        end
      end

      context = %Context{event_id: "test", data: %{}, metadata: %{}}

      assert {:error, %RuntimeError{}} =
               EventResolver.generate_send_variables(RaisingGenerateVarsModule, context, %{})
    end
  end
end
