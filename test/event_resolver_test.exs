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
    test "returns the module's address" do
      defmodule WithReplyTo do
        def reply_to(_context, _channel), do: "sales-rep@example.com"
      end

      assert EventResolver.reply_to(WithReplyTo, ctx(), customer_channel()) ==
               "sales-rep@example.com"
    end

    test "a module without the callback gives nil — the behaviour before 0.8.1" do
      defmodule WithoutReplyTo do
      end

      assert EventResolver.reply_to(WithoutReplyTo, ctx(), customer_channel()) == nil
    end

    # This is the load-bearing half: an email that never leaves costs more than
    # an email without a reply header.
    test "junk is treated as nil rather than bringing the send down" do
      defmodule JunkReplyTo do
        def reply_to(_context, _channel), do: {"Name", "a@b.se"}
      end

      defmodule EmptyReplyTo do
        def reply_to(_context, _channel), do: ""
      end

      assert EventResolver.reply_to(JunkReplyTo, ctx(), customer_channel()) == nil
      assert EventResolver.reply_to(EmptyReplyTo, ctx(), customer_channel()) == nil
    end

    @tag :capture_log
    test "a callback that raises gives nil, not a crashed send" do
      defmodule RaisingReplyTo do
        def reply_to(_context, _channel), do: raise("boom")
      end

      assert EventResolver.reply_to(RaisingReplyTo, ctx(), customer_channel()) == nil
    end

    defp ctx, do: %Context{event_id: "test", data: %{}, metadata: %{}}
    defp customer_channel, do: %Channel{transport: :email, audience: :customer}
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
