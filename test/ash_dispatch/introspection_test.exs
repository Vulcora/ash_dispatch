defmodule AshDispatch.IntrospectionTest do
  use ExUnit.Case, async: true

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
    setup do
      # Ensure test config is set
      Application.put_env(:ash_dispatch_test, :ash_domains, [AshDispatch.Test.Domain])

      on_exit(fn ->
        Application.delete_env(:ash_dispatch_test, :ash_domains)
      end)

      :ok
    end

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
      # Domain is derived from AshDispatch.Test.Domain -> "Domain" -> :domain -> "Domain"
      # So module is: {OtpApp}.{Domain}.Events.{Event}.Event
      assert ticket_created.module_name == AshDispatchTest.Domain.Events.Created.Event
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
    setup do
      Application.put_env(:ash_dispatch_test, :ash_domains, [AshDispatch.Test.Domain])

      on_exit(fn ->
        Application.delete_env(:ash_dispatch_test, :ash_domains)
      end)

      :ok
    end

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
    test "returns convention-based path for inline events without module" do
      event_info = %{
        module: nil,
        domain: :orders,
        resource_name: "product_order",
        name: :created
      }

      result = Introspection.template_directory(event_info, :my_app)

      assert result == "lib/my_app/orders/templates/product_order/created"
    end

    test "returns module-based path for events with module" do
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

    test "falls back to event name when resource_name is nil" do
      event_info = %{
        module: nil,
        domain: :tickets,
        resource_name: nil,
        name: :assigned
      }

      result = Introspection.template_directory(event_info, :acme)

      assert result == "lib/acme/tickets/templates/assigned/assigned"
    end
  end

  describe "dispatch_resources/1" do
    setup do
      Application.put_env(:ash_dispatch_test, :ash_domains, [AshDispatch.Test.Domain])

      on_exit(fn ->
        Application.delete_env(:ash_dispatch_test, :ash_domains)
      end)

      :ok
    end

    test "returns resources with AshDispatch.Resource extension" do
      resources = Introspection.dispatch_resources(:ash_dispatch_test)

      assert AshDispatch.Test.Ticket in resources
      assert AshDispatch.Test.Order in resources
    end
  end
end
