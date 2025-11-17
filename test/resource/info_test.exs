defmodule AshDispatch.Resource.InfoTest do
  @moduledoc """
  Tests for AshDispatch.Resource.Info introspection module.
  """

  use ExUnit.Case, async: true

  alias AshDispatch.Resource.Info
  alias AshDispatch.Test.TestProduct

  describe "events/1" do
    test "returns all events for a resource" do
      events = Info.events(TestProduct)

      assert length(events) == 3
      assert Enum.all?(events, &(&1.__struct__ == AshDispatch.Resource.Dsl.Event))
    end

    test "returns event structs with all fields populated" do
      events = Info.events(TestProduct)
      created_event = Enum.find(events, &(&1.name == :created))

      assert created_event.name == :created
      assert created_event.trigger_on == :create
      assert created_event.channels == [[transport: :in_app, audience: :user]]
      assert is_list(created_event.content)
      assert is_list(created_event.metadata)
    end
  end

  describe "event/2" do
    test "returns specific event by name" do
      event = Info.event(TestProduct, :created)

      assert event.name == :created
      assert event.trigger_on == :create
    end

    test "returns nil for non-existent event" do
      event = Info.event(TestProduct, :nonexistent)

      assert is_nil(event)
    end
  end

  describe "events_for_action/2" do
    test "returns events triggered by single action" do
      events = Info.events_for_action(TestProduct, :create)

      assert length(events) == 1
      assert hd(events).name == :created
    end

    test "returns events triggered by action in list of triggers" do
      events = Info.events_for_action(TestProduct, :activate)

      assert length(events) == 1
      assert hd(events).name == :status_changed
    end

    test "returns multiple events if action triggers multiple" do
      # Cancel triggers both :status_changed and :cancelled
      events = Info.events_for_action(TestProduct, :cancel)

      assert length(events) == 2

      event_names = Enum.map(events, & &1.name) |> Enum.sort()
      assert event_names == [:cancelled, :status_changed]
    end

    test "returns empty list for action with no events" do
      events = Info.events_for_action(TestProduct, :destroy)

      assert events == []
    end
  end

  describe "dispatch_enabled?/1" do
    test "returns true for resource with AshDispatch.Resource extension" do
      assert Info.dispatch_enabled?(TestProduct) == true
    end

    test "returns false for resource without extension" do
      # TestDomain doesn't have the extension
      assert Info.dispatch_enabled?(AshDispatch.Test.TestDomain) == false
    end
  end

  describe "event_ids/1" do
    test "returns list of event IDs" do
      event_ids = Info.event_ids(TestProduct)

      # Event IDs are auto-generated or nil
      # Our test events don't have explicit event_ids, so they'll be nil
      # The transformer generates them, but they're not in the DSL state yet
      assert is_list(event_ids)
    end
  end

  describe "events_with_modules/1" do
    test "returns events that have callback modules" do
      events = Info.events_with_modules(TestProduct)

      assert length(events) == 1
      assert hd(events).name == :cancelled
      assert hd(events).module == AshDispatch.Test.CustomEventModule
    end
  end

  describe "inline_events/1" do
    test "returns events that use inline configuration" do
      events = Info.inline_events(TestProduct)

      assert length(events) == 2

      event_names = Enum.map(events, & &1.name) |> Enum.sort()
      assert event_names == [:created, :status_changed]
    end
  end

  describe "event_count/1" do
    test "returns total number of events" do
      count = Info.event_count(TestProduct)

      assert count == 3
    end
  end

  describe "event struct fields" do
    test "can access event fields directly" do
      event = Info.event(TestProduct, :created)

      assert event.name == :created
      assert event.trigger_on == :create
      assert event.module == nil
      assert event.channels == [[transport: :in_app, audience: :user]]
      assert event.content[:notification_title] == "Product created"
      assert event.metadata[:notification_type] == :success
      assert event.load == []
    end

    test "events with callback modules have module field set" do
      event = Info.event(TestProduct, :cancelled)

      assert event.module == AshDispatch.Test.CustomEventModule
    end

    test "events with multiple triggers have list in trigger_on" do
      event = Info.event(TestProduct, :status_changed)

      assert event.trigger_on == [:activate, :cancel]
    end
  end

  describe "practical usage patterns" do
    test "can find all email channels across all events" do
      events = Info.events(TestProduct)

      email_events =
        Enum.filter(events, fn event ->
          Enum.any?(event.channels, fn channel ->
            channel[:transport] == :email
          end)
        end)

      # status_changed has email channels
      assert length(email_events) == 1
      assert hd(email_events).name == :status_changed
    end

    test "can build event dispatch map" do
      events = Info.events(TestProduct)

      # Group events by action
      action_to_events =
        Enum.reduce(events, %{}, fn event, acc ->
          trigger_on = event.trigger_on

          actions = if is_list(trigger_on), do: trigger_on, else: [trigger_on]

          Enum.reduce(actions, acc, fn action, inner_acc ->
            Map.update(inner_acc, action, [event.name], fn existing ->
              [event.name | existing]
            end)
          end)
        end)

      assert Map.has_key?(action_to_events, :create)
      assert Map.has_key?(action_to_events, :activate)
      assert Map.has_key?(action_to_events, :cancel)
      assert action_to_events[:create] == [:created]
    end

    test "can check if action has events before dispatching" do
      # Useful for conditional logic
      has_events_for_create = Info.events_for_action(TestProduct, :create) != []
      has_events_for_destroy = Info.events_for_action(TestProduct, :destroy) != []

      assert has_events_for_create == true
      assert has_events_for_destroy == false
    end
  end
end
