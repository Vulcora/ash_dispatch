defmodule AshDispatch.PriorityTest do
  use ExUnit.Case, async: false

  alias AshDispatch.Changes.DispatchEvent

  describe "priority DSL field" do
    test "default priority is :standard" do
      # Ticket.created has no explicit priority
      action = Ash.Resource.Info.action(AshDispatch.Test.Ticket, :create)

      dispatch_change =
        Enum.find(action.changes, fn change ->
          match?(%Ash.Resource.Change{change: {DispatchEvent, _}}, change)
        end)

      {DispatchEvent, opts} = dispatch_change.change
      event_config = Keyword.get(opts, :event_config)

      assert event_config.priority == :standard
    end

    test "explicit priority is preserved in event_config" do
      # Ticket.escalated has priority: :urgent
      action = Ash.Resource.Info.action(AshDispatch.Test.Ticket, :close)

      dispatch_change =
        Enum.find(action.changes, fn change ->
          match?(%Ash.Resource.Change{change: {DispatchEvent, _}}, change)
        end)

      {DispatchEvent, opts} = dispatch_change.change
      event_config = Keyword.get(opts, :event_config)

      assert event_config.priority == :urgent
    end
  end

  describe "priority in Context struct" do
    test "Context.new defaults priority to :standard" do
      context = AshDispatch.Context.new(event_id: "test.event", data: %{})
      assert context.priority == :standard
    end

    test "Context struct accepts priority field" do
      context = %AshDispatch.Context{
        event_id: "test.urgent",
        data: %{},
        priority: :urgent
      }

      assert context.priority == :urgent
    end
  end

  describe "priority in Event DSL struct" do
    test "Event struct has priority field with default" do
      event = %AshDispatch.Resource.Dsl.Event{
        name: :test,
        trigger_on: :create
      }

      assert event.priority == :standard
    end

    test "Event struct accepts all priority values" do
      for priority <- [:urgent, :standard, :informational] do
        event = %AshDispatch.Resource.Dsl.Event{
          name: :test,
          trigger_on: :create,
          priority: priority
        }

        assert event.priority == priority
      end
    end
  end
end
