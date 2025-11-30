defmodule AshDispatch.IntrospectionTest do
  # Disable async because tests depend on Application config set in test_helper.exs
  use ExUnit.Case, async: false

  alias AshDispatch.Introspection

  describe "derive_module_name/2" do
    test "derives correct module name from event info" do
      event_info = %{
        domain: :orders,
        name: :created
      }

      result = Introspection.derive_module_name(event_info, :my_app)

      assert result == MyApp.Orders.Events.Created.Event
    end

    test "handles underscored domain names" do
      event_info = %{
        domain: :product_orders,
        name: :status_changed
      }

      result = Introspection.derive_module_name(event_info, :my_app)

      assert result == MyApp.ProductOrders.Events.StatusChanged.Event
    end

    test "handles different otp_app names" do
      event_info = %{
        domain: :tickets,
        name: :assigned
      }

      result = Introspection.derive_module_name(event_info, :acme_support)

      assert result == AcmeSupport.Tickets.Events.Assigned.Event
    end
  end

  describe "missing_event_modules/1" do
    # Config is set in test_helper.exs:
    # Application.put_env(:ash_dispatch_test, :ash_domains, [AshDispatch.Test.Domain])

    test "returns events without explicit module that need generation" do
      # Get missing modules for our test app
      missing = Introspection.missing_event_modules(:ash_dispatch_test)

      # Should include Ticket events (no explicit module)
      event_ids = Enum.map(missing, & &1.event_id)

      assert "ticket.created" in event_ids
      assert "ticket.assigned" in event_ids
    end

    test "excludes events with explicit module override" do
      missing = Introspection.missing_event_modules(:ash_dispatch_test)

      # Order.created has explicit module: AshDispatch.Test.Events.OrderCreated
      # So it should NOT be in missing modules list
      event_ids = Enum.map(missing, & &1.event_id)

      refute "order.created" in event_ids
    end

    test "returns correct module paths" do
      missing = Introspection.missing_event_modules(:ash_dispatch_test)

      # Find the ticket.created event
      ticket_created = Enum.find(missing, &(&1.event_id == "ticket.created"))

      assert ticket_created != nil
      # Domain is derived from resource namespace: AshDispatch.Test.Ticket -> "Test"
      # So module is: {OtpApp}.{Domain}.Events.{Event}.Event
      assert ticket_created.module_name == AshDispatchTest.Test.Events.Created.Event
      assert String.ends_with?(ticket_created.module_path, "events/created/event.ex")
    end

    test "marks non-existent modules as needing generation" do
      missing = Introspection.missing_event_modules(:ash_dispatch_test)

      # All returned modules should have exists: false
      # (since we haven't generated them)
      for module_info <- missing do
        assert module_info.exists == false
      end
    end
  end

  describe "all_events/1" do
    # Config is set in test_helper.exs

    test "returns all inline events from resources" do
      events = Introspection.all_events(:ash_dispatch_test)

      event_ids = Enum.map(events, & &1.event_id)

      # Should find all events from both Ticket and Order
      assert "ticket.created" in event_ids
      assert "ticket.assigned" in event_ids
      assert "order.created" in event_ids
    end

    test "includes event module when explicitly set" do
      events = Introspection.all_events(:ash_dispatch_test)

      order_created = Enum.find(events, &(&1.event_id == "order.created"))

      assert order_created != nil
      assert order_created.module == AshDispatch.Test.Events.OrderCreated
    end

    test "has nil module for inline events without explicit module" do
      events = Introspection.all_events(:ash_dispatch_test)

      ticket_created = Enum.find(events, &(&1.event_id == "ticket.created"))

      assert ticket_created != nil
      assert ticket_created.module == nil
    end
  end

  describe "template_directory/2" do
    test "returns module-based path for inline events (derived from domain/name)" do
      event_info = %{
        module: nil,
        domain: :orders,
        resource_name: "product_order",
        name: :created
      }

      result = Introspection.template_directory(event_info, :my_app)

      # Always uses module-based path: lib/{app}/{domain}/events/{event}/templates
      assert result == "lib/my_app/orders/events/created/templates"
    end

    test "returns module-based path for events with explicit module" do
      event_info = %{
        module: MyApp.Orders.Events.Created.Event,
        domain: :orders,
        name: :created
      }

      result = Introspection.template_directory(event_info, :my_app)

      # Should use module path + /templates
      assert String.ends_with?(result, "/templates")
      assert String.contains?(result, "my_app/orders/events/created")
    end

    test "derives path from domain and event name" do
      event_info = %{
        module: nil,
        domain: :tickets,
        resource_name: nil,
        name: :assigned
      }

      result = Introspection.template_directory(event_info, :acme)

      # Always uses module-based path structure
      assert result == "lib/acme/tickets/events/assigned/templates"
    end
  end

  describe "dispatch_resources/1" do
    # Config is set in test_helper.exs

    test "returns resources with AshDispatch.Resource extension" do
      resources = Introspection.dispatch_resources(:ash_dispatch_test)

      assert AshDispatch.Test.Ticket in resources
      assert AshDispatch.Test.Order in resources
    end
  end
end
