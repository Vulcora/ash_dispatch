defmodule AshDispatch.EventRegistryTest do
  # Disable async because tests modify Application config
  use ExUnit.Case, async: false

  alias AshDispatch.EventRegistry

  # Config is set in test_helper.exs:
  # Application.put_env(:ash_dispatch_test, :ash_domains, [AshDispatch.Test.Domain])

  describe "all_events/1" do
    test "discovers all events from domain resources" do
      events = EventRegistry.all_events(:ash_dispatch_test)

      event_ids = Enum.map(events, & &1.event_id)

      # Should find events from both Ticket and Order resources
      assert "ticket.created" in event_ids
      assert "ticket.assigned" in event_ids
      assert "order.created" in event_ids
    end

    test "includes event module when explicitly set in DSL" do
      events = EventRegistry.all_events(:ash_dispatch_test)

      # Order.created has explicit module: AshDispatch.Test.Events.OrderCreated
      order_created = Enum.find(events, &(&1.event_id == "order.created"))

      assert order_created != nil
      assert order_created.module == AshDispatch.Test.Events.OrderCreated
    end

    test "has nil module for inline events without explicit module" do
      events = EventRegistry.all_events(:ash_dispatch_test)

      # Ticket events don't have explicit module
      ticket_created = Enum.find(events, &(&1.event_id == "ticket.created"))

      assert ticket_created != nil
      assert ticket_created.module == nil
    end
  end

  describe "find_event/2" do
    test "finds event by event_id" do
      result = EventRegistry.find_event("order.created", :ash_dispatch_test)

      assert {:ok, event} = result
      assert event.event_id == "order.created"
      assert event.module == AshDispatch.Test.Events.OrderCreated
    end

    test "returns error for unknown event_id" do
      result = EventRegistry.find_event("unknown.event", :ash_dispatch_test)

      assert {:error, :not_found} = result
    end
  end

  describe "find_module/2" do
    test "finds module for event with explicit module" do
      result = EventRegistry.find_module("order.created", :ash_dispatch_test)

      assert {:ok, AshDispatch.Test.Events.OrderCreated} = result
    end

    test "returns error for event without module" do
      result = EventRegistry.find_module("ticket.created", :ash_dispatch_test)

      assert {:error, :no_module} = result
    end

    test "returns error for unknown event" do
      result = EventRegistry.find_module("unknown.event", :ash_dispatch_test)

      assert {:error, :not_found} = result
    end
  end

  describe "event_modules/1" do
    test "returns list of {event_id, module} tuples for events with modules" do
      modules = EventRegistry.event_modules(:ash_dispatch_test)

      # Should be a list of tuples
      assert is_list(modules)

      # Order.created has explicit module
      assert {"order.created", AshDispatch.Test.Events.OrderCreated} in modules

      # Ticket events don't have modules, so they shouldn't be in the list
      event_ids = Enum.map(modules, fn {id, _mod} -> id end)
      refute "ticket.created" in event_ids
      refute "ticket.assigned" in event_ids
    end

    test "format matches legacy config format for backward compatibility" do
      modules = EventRegistry.event_modules(:ash_dispatch_test)

      # Each entry should be {string_event_id, module_atom}
      Enum.each(modules, fn {event_id, module} ->
        assert is_binary(event_id)
        assert is_atom(module)
      end)
    end
  end

  describe "get_event_modules/0 (using configured otp_app)" do
    setup do
      # Configure the otp_app that EventRegistry should use
      old_otp_app = Application.get_env(:ash_dispatch, :otp_app)
      Application.put_env(:ash_dispatch, :otp_app, :ash_dispatch_test)

      on_exit(fn ->
        if old_otp_app do
          Application.put_env(:ash_dispatch, :otp_app, old_otp_app)
        else
          Application.delete_env(:ash_dispatch, :otp_app)
        end
      end)

      :ok
    end

    test "uses configured otp_app when no argument provided" do
      modules = EventRegistry.get_event_modules()

      # Should find the order.created module
      assert {"order.created", AshDispatch.Test.Events.OrderCreated} in modules
    end
  end
end
