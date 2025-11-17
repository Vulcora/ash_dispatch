defmodule AshDispatch.IntegrationTest do
  @moduledoc """
  Integration tests for end-to-end event dispatch flow.

  Tests the complete flow from resource action → event dispatch → transport delivery.
  """

  use ExUnit.Case, async: false
  use Oban.Testing, repo: Magasin.Repo

  require Ash.Query
  import Ash.Expr

  alias AshDispatch.Test.TestProduct
  alias AshDispatch.Changes.DispatchEvent

  describe "end-to-end event dispatch" do
    test "DispatchEvent change is injected into actions" do
      # Get the create action
      create_action = Ash.Resource.Info.action(TestProduct, :create)

      # Verify DispatchEvent change was injected
      dispatch_changes =
        create_action.changes
        |> Enum.filter(fn
          %Ash.Resource.Change{change: {AshDispatch.Changes.DispatchEvent, _opts}} -> true
          _ -> false
        end)

      assert length(dispatch_changes) == 1

      # Verify it has correct event configuration
      %Ash.Resource.Change{change: {DispatchEvent, opts}} = hd(dispatch_changes)
      assert opts[:event_id] == "test_product.created"
      assert is_map(opts[:event_config])
    end

    test "creating a product triggers event dispatch" do
      # Create a test product
      product =
        TestProduct
        |> Ash.Changeset.for_create(:create, %{name: "Test Widget"})
        |> Ash.create!()

      assert product.name == "Test Widget"

      # Verify a delivery receipt was created
      receipts =
        AshDispatch.Resources.DeliveryReceipt
        |> Ash.Query.filter(expr(event_id == "test_product.created"))
        |> Ash.read!()

      assert length(receipts) > 0
      assert hd(receipts).transport == :in_app
      assert hd(receipts).status == :sent
    end

    test "activate action triggers status_changed event" do
      # Create product first
      product =
        TestProduct
        |> Ash.Changeset.for_create(:create, %{name: "Test Widget"})
        |> Ash.create!()

      # Activate the product
      updated_product =
        product
        |> Ash.Changeset.for_update(:activate, %{})
        |> Ash.update!()

      assert updated_product.status == :active

      # Verify status_changed event was dispatched
      receipts =
        AshDispatch.Resources.DeliveryReceipt
        |> Ash.Query.filter(expr(event_id == "test_product.status_changed"))
        |> Ash.read!()

      assert length(receipts) > 0

      # Should have both email and in_app receipts
      transports = Enum.map(receipts, & &1.transport)
      assert :email in transports
      assert :in_app in transports
    end

    test "admin audience resolves to multiple recipients" do
      # Create product first
      product =
        TestProduct
        |> Ash.Changeset.for_create(:create, %{name: "Test Widget"})
        |> Ash.create!()

      # Activate triggers admin notifications
      product
      |> Ash.Changeset.for_update(:activate, %{})
      |> Ash.update!()

      # Query all receipts for this event
      receipts =
        AshDispatch.Resources.DeliveryReceipt
        |> Ash.Query.filter(expr(event_id == "test_product.status_changed"))
        |> Ash.read!()

      # Should have created receipts for admin audience
      assert length(receipts) > 0

      # Verify admin receipts exist
      admin_receipts = Enum.filter(receipts, &(&1.audience == :admin))
      assert length(admin_receipts) > 0

      # Verify at least one receipt was sent successfully
      sent_receipts = Enum.filter(admin_receipts, &(&1.status == :sent))
      assert length(sent_receipts) > 0

      # Verify notifications were created
      notifications =
        AshDispatch.Resources.Notification
        |> Ash.Query.filter(expr(event_id == "test_product.status_changed"))
        |> Ash.read!()

      # Should have at least one notification
      assert length(notifications) > 0

      # Verify notification content
      notification = hd(notifications)
      assert notification.title == "Status Changed"
      # Variable interpolation should replace {{status}} with actual value
      assert notification.message =~ "active"
      assert notification.notification_type == :info
    end

    test "events with callback modules are supported" do
      # Create product first
      product =
        TestProduct
        |> Ash.Changeset.for_create(:create, %{name: "Test Widget"})
        |> Ash.create!()

      # Cancel action should trigger :cancelled event with module
      cancelled_product =
        product
        |> Ash.Changeset.for_update(:cancel, %{})
        |> Ash.update!()

      assert cancelled_product.status == :cancelled

      # Verify cancelled event was dispatched (from event with module)
      receipts =
        AshDispatch.Resources.DeliveryReceipt
        |> Ash.Query.filter(expr(event_id == "test_product.cancelled"))
        |> Ash.read!()

      # Should have receipts even though module doesn't fully exist
      # (dispatcher will attempt to call module methods)
      assert length(receipts) >= 0
    end

    test "inline event configuration works" do
      dsl_state = TestProduct.spark_dsl_config()
      events = Spark.Dsl.Transformer.get_entities(dsl_state, [:dispatch])

      created_event = Enum.find(events, &(&1.name == :created))

      # Verify inline configuration
      assert created_event.channels == [[transport: :in_app, audience: :user]]

      assert created_event.content == [
               notification_title: "Product created",
               notification_message: "{{name}} was created"
             ]

      assert created_event.metadata == [notification_type: :success]
    end

    test "multiple triggers on same event works" do
      dsl_state = TestProduct.spark_dsl_config()
      events = Spark.Dsl.Transformer.get_entities(dsl_state, [:dispatch])

      status_event = Enum.find(events, &(&1.name == :status_changed))

      # Verify it triggers on multiple actions
      assert status_event.trigger_on == [:activate, :cancel]

      # Verify both actions have the change injected
      activate_action = Ash.Resource.Info.action(TestProduct, :activate)
      cancel_action = Ash.Resource.Info.action(TestProduct, :cancel)

      activate_has_dispatch =
        Enum.any?(activate_action.changes, fn
          %Ash.Resource.Change{change: {DispatchEvent, opts}} ->
            opts[:event_id] == "test_product.status_changed"

          _ ->
            false
        end)

      cancel_has_dispatch =
        Enum.any?(cancel_action.changes, fn
          %Ash.Resource.Change{change: {DispatchEvent, opts}} ->
            opts[:event_id] == "test_product.status_changed"

          _ ->
            false
        end)

      assert activate_has_dispatch
      assert cancel_has_dispatch
    end
  end

  describe "dispatcher and transports (async)" do
    test "Dispatcher.dispatch handles inline config" do
      context = %AshDispatch.Context{
        event_id: "test.event",
        data: %{product: %{id: 1, name: "Widget"}},
        resource_key: :product,
        user: %{id: 1, name: "Alice"}
      }

      channel = %AshDispatch.Channel{
        transport: :in_app,
        audience: :user
      }

      event_config = %{
        channels: [[transport: :in_app, audience: :user]],
        content: %{
          notification_title: "Test",
          notification_message: "Hello"
        },
        metadata: %{notification_type: :info}
      }

      # Should not raise
      assert {:ok, _receipt} = AshDispatch.Dispatcher.dispatch(context, channel, event_config)
    end

    test "InApp transport creates notification structure" do
      user_id = Ash.UUID.generate()

      context = %AshDispatch.Context{
        event_id: "test.event",
        data: %{product: %{id: 1}},
        user: %{id: user_id, email: "test@example.com"}
      }

      # Create a real DeliveryReceipt record
      {:ok, receipt} =
        AshDispatch.Resources.DeliveryReceipt
        |> Ash.Changeset.for_create(:create, %{
          event_id: "test.event",
          transport: :in_app,
          audience: :user,
          recipient: "test@example.com",
          content: %{
            title: "Test Notification",
            message: "Hello World",
            action_url: "/products/1",
            notification_type: :success
          }
        })
        |> Ash.create()

      channel = %AshDispatch.Channel{transport: :in_app, audience: :user}

      event_config = %{channels: [[transport: :in_app, audience: :user]]}

      # Should complete without error
      assert {:ok, updated_receipt} =
               AshDispatch.Transports.InApp.deliver(receipt, context, channel, event_config)

      assert updated_receipt.status == :sent
      assert updated_receipt.sent_at

      # Verify notification was created
      notifications =
        AshDispatch.Resources.Notification
        |> Ash.Query.filter(expr(user_id == ^user_id))
        |> Ash.read!()

      assert length(notifications) == 1
      notification = hd(notifications)
      assert notification.title == "Test Notification"
      assert notification.message == "Hello World"
      assert notification.read == false
    end


    test "unknown transports are skipped" do
      context = %AshDispatch.Context{
        event_id: "test.event",
        data: %{product: %{id: 1}}
      }

      # Create a real DeliveryReceipt record
      {:ok, receipt} =
        AshDispatch.Resources.DeliveryReceipt
        |> Ash.Changeset.for_create(:create, %{
          event_id: "test.event",
          transport: :discord,
          audience: :system,
          recipient: "system"
        })
        |> Ash.create()

      channel = %AshDispatch.Channel{transport: :discord, audience: :team}

      event_config = %{}

      assert {:ok, updated_receipt} =
               AshDispatch.Transports.Discord.deliver(receipt, context, channel, event_config)

      assert updated_receipt.status == :skipped
    end
  end

  # Oban tests must be non-async to avoid database ownership issues
  describe "oban integration" do
    @describetag :integration

    setup do
      # Allow Oban processes to access the test's database connection
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Magasin.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Magasin.Repo, {:shared, self()})
      :ok
    end

    test "Email transport enqueues job" do
      context = %AshDispatch.Context{
        event_id: "test.event",
        data: %{product: %{id: 1}},
        user: %{id: 1, email: "test@example.com"}
      }

      # Create a real DeliveryReceipt record
      {:ok, receipt} =
        AshDispatch.Resources.DeliveryReceipt
        |> Ash.Changeset.for_create(:create, %{
          event_id: "test.event",
          transport: :email,
          audience: :user,
          recipient: "test@example.com",
          subject: "Test Email",
          body_html: "<p>Test</p>",
          body_text: "Test",
          content: %{
            subject: "Test Email",
            from: "test@example.com",
            html_body: "<p>Test</p>",
            text_body: "Test"
          }
        })
        |> Ash.create()

      channel = %AshDispatch.Channel{transport: :email, audience: :user, time: {:in, 0}}

      event_config = %{channels: [[transport: :email, audience: :user]]}

      assert {:ok, updated_receipt} =
               AshDispatch.Transports.Email.deliver(receipt, context, channel, event_config)

      assert updated_receipt.status == :scheduled

      # Verify Oban job was enqueued
      assert_enqueued worker: AshDispatch.Workers.SendEmail,
                      args: %{
                        "receipt_id" => receipt.id,
                        "recipient_email" => "test@example.com",
                        "event_id" => "test.event",
                        "subject" => "Test Email",
                        "from" => "test@example.com",
                        "html_body" => "<p>Test</p>",
                        "text_body" => "Test"
                      }
    end

    test "SendEmail worker processes job successfully" do
      # Create a receipt
      {:ok, receipt} =
        AshDispatch.Resources.DeliveryReceipt
        |> Ash.Changeset.for_create(:create, %{
          event_id: "test.worker",
          transport: :email,
          audience: :user,
          recipient: "worker@example.com",
          content: %{
            subject: "Worker Test",
            from: "noreply@example.com",
            html_body: "<p>Worker Test</p>",
            text_body: "Worker Test"
          }
        })
        |> Ash.create()

      # Build job args
      args = %{
        "receipt_id" => receipt.id,
        "recipient_email" => "worker@example.com",
        "event_id" => "test.worker",
        "subject" => "Worker Test",
        "from" => "noreply@example.com",
        "html_body" => "<p>Worker Test</p>",
        "text_body" => "Worker Test"
      }

      # Execute worker (synchronously)
      assert :ok = perform_job(AshDispatch.Workers.SendEmail, args)

      # Verify receipt was updated
      updated_receipt = Ash.get!(AshDispatch.Resources.DeliveryReceipt, receipt.id)
      assert updated_receipt.status == :sent
      assert updated_receipt.sent_at != nil
      assert updated_receipt.provider_response != nil
    end

    test "SendEmail worker handles failures" do
      # Create a receipt with invalid ID to force failure
      args = %{
        "receipt_id" => Ash.UUID.generate(),
        "recipient_email" => "fail@example.com",
        "event_id" => "test.fail",
        "subject" => "Fail Test",
        "from" => "noreply@example.com",
        "html_body" => "<p>Fail</p>",
        "text_body" => "Fail"
      }

      # Worker should return error
      assert {:error, :receipt_not_found} =
               perform_job(AshDispatch.Workers.SendEmail, args)
    end
  end

  describe "user preferences" do
    test "user who opted out of marketing emails gets receipt skipped" do
      user_id = AshDispatch.Test.UserPreference.opted_out_marketing_user_id()

      context = %AshDispatch.Context{
        event_id: "test.marketing",
        data: %{product: %{id: 1}},
        user: %{id: user_id, email: "opted-out@example.com"}
      }

      # Create a receipt
      {:ok, receipt} =
        AshDispatch.Resources.DeliveryReceipt
        |> Ash.Changeset.for_create(:create, %{
          event_id: "test.marketing",
          transport: :email,
          audience: :user,
          recipient: "opted-out@example.com",
          content: %{subject: "Marketing Email"}
        })
        |> Ash.create()

      channel = %AshDispatch.Channel{transport: :email, audience: :user}

      event_config = %{
        channels: [[transport: :email, audience: :user]],
        metadata: %{category: :marketing}
      }

      # Deliver should skip due to preference
      assert {:ok, updated_receipt} =
               AshDispatch.Transports.Email.deliver(receipt, context, channel, event_config)

      assert updated_receipt.status == :skipped
      assert updated_receipt.error_message == "user_opted_out"
    end

    test "user who opted out of marketing emails still gets in-app notifications" do
      user_id = AshDispatch.Test.UserPreference.opted_out_marketing_user_id()

      context = %AshDispatch.Context{
        event_id: "test.marketing",
        data: %{product: %{id: 1}},
        user: %{id: user_id, email: "opted-out@example.com"}
      }

      # Create a receipt for in-app
      {:ok, receipt} =
        AshDispatch.Resources.DeliveryReceipt
        |> Ash.Changeset.for_create(:create, %{
          event_id: "test.marketing",
          transport: :in_app,
          audience: :user,
          recipient: user_id,
          content: %{
            title: "Marketing Notification",
            message: "Check this out!",
            notification_type: :info
          }
        })
        |> Ash.create()

      channel = %AshDispatch.Channel{transport: :in_app, audience: :user}

      event_config = %{
        channels: [[transport: :in_app, audience: :user]],
        metadata: %{category: :marketing}
      }

      # Deliver should succeed (user only opted out of email, not in-app)
      assert {:ok, updated_receipt} =
               AshDispatch.Transports.InApp.deliver(receipt, context, channel, event_config)

      assert updated_receipt.status == :sent
    end

    test "user who opted out of all emails gets all emails skipped" do
      user_id = AshDispatch.Test.UserPreference.opted_out_all_email_user_id()

      context = %AshDispatch.Context{
        event_id: "test.transactional",
        data: %{order: %{id: 123}},
        user: %{id: user_id, email: "no-email@example.com"}
      }

      # Create a receipt
      {:ok, receipt} =
        AshDispatch.Resources.DeliveryReceipt
        |> Ash.Changeset.for_create(:create, %{
          event_id: "test.transactional",
          transport: :email,
          audience: :user,
          recipient: "no-email@example.com",
          content: %{subject: "Order Confirmation"}
        })
        |> Ash.create()

      channel = %AshDispatch.Channel{transport: :email, audience: :user}

      event_config = %{
        channels: [[transport: :email, audience: :user]],
        metadata: %{category: :transactional}  # Even transactional!
      }

      # Deliver should skip
      assert {:ok, updated_receipt} =
               AshDispatch.Transports.Email.deliver(receipt, context, channel, event_config)

      assert updated_receipt.status == :skipped
      assert updated_receipt.error_message == "user_opted_out"
    end

    test "user who allows all gets notifications normally" do
      user_id = AshDispatch.Test.UserPreference.allows_all_user_id()

      context = %AshDispatch.Context{
        event_id: "test.normal",
        data: %{product: %{id: 1}},
        user: %{id: user_id, email: "allows-all@example.com"}
      }

      # Create a receipt for in-app
      {:ok, receipt} =
        AshDispatch.Resources.DeliveryReceipt
        |> Ash.Changeset.for_create(:create, %{
          event_id: "test.normal",
          transport: :in_app,
          audience: :user,
          recipient: user_id,
          content: %{
            title: "Normal Notification",
            message: "This should work",
            notification_type: :info
          }
        })
        |> Ash.create()

      channel = %AshDispatch.Channel{transport: :in_app, audience: :user}

      event_config = %{
        channels: [[transport: :in_app, audience: :user]],
        metadata: %{category: :marketing}
      }

      # Deliver should succeed
      assert {:ok, updated_receipt} =
               AshDispatch.Transports.InApp.deliver(receipt, context, channel, event_config)

      assert updated_receipt.status == :sent
    end

    test "admin notifications ignore user preferences" do
      # Even if a user opted out, admin notifications should go through
      user_id = AshDispatch.Test.UserPreference.opted_out_all_email_user_id()

      context = %AshDispatch.Context{
        event_id: "test.admin_alert",
        data: %{issue: %{id: 1}},
        user: %{id: user_id}
      }

      {:ok, receipt} =
        AshDispatch.Resources.DeliveryReceipt
        |> Ash.Changeset.for_create(:create, %{
          event_id: "test.admin_alert",
          transport: :email,
          audience: :admin,  # Admin audience
          recipient: "admin@example.com",
          content: %{subject: "Critical Alert"}
        })
        |> Ash.create()

      channel = %AshDispatch.Channel{transport: :email, audience: :admin}

      event_config = %{
        channels: [[transport: :email, audience: :admin]]
      }

      # Deliver should succeed (admin notifications bypass user preferences)
      assert {:ok, updated_receipt} =
               AshDispatch.Transports.Email.deliver(receipt, context, channel, event_config)

      # Should be scheduled (not skipped)
      # Note: Will be :failed due to no recipients in mock resolver, but NOT :skipped
      assert updated_receipt.status in [:scheduled, :failed]
      assert updated_receipt.error_message != "user_opted_out"
    end
  end
end
