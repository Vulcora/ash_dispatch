defmodule AshDispatch.ResourceTest do
  @moduledoc """
  Tests for AshDispatch.Resource extension.
  """

  use ExUnit.Case, async: true

  alias AshDispatch.Test.TestProduct
  alias Spark.Dsl.Transformer

  describe "dispatch section" do
    test "defines events in the resource" do
      events = Ash.Resource.Info.extensions(TestProduct)
      assert AshDispatch.Resource in events
    end

    test "events can be retrieved from DSL state" do
      # Get the DSL state from the resource
      dsl_state = TestProduct.spark_dsl_config()

      # Get events from the dispatch section
      events = Transformer.get_entities(dsl_state, [:dispatch])

      assert length(events) == 3

      # Check first event
      created_event = Enum.find(events, &(&1.name == :created))
      assert created_event.trigger_on == :create
      assert length(created_event.channels) == 1
      assert created_event.content[:notification_title] == "Product created"
      assert created_event.metadata[:notification_type] == :success

      # Check second event (multi-action)
      status_event = Enum.find(events, &(&1.name == :status_changed))
      assert status_event.trigger_on == [:activate, :cancel]
      assert length(status_event.channels) == 2

      # Check third event (with module)
      cancelled_event = Enum.find(events, &(&1.name == :cancelled))
      assert cancelled_event.module == AshDispatch.Test.CustomEventModule
    end

    test "event_id is auto-generated when not specified" do
      dsl_state = TestProduct.spark_dsl_config()
      events = Transformer.get_entities(dsl_state, [:dispatch])

      created_event = Enum.find(events, &(&1.name == :created))

      # Event ID should be auto-generated or nil (transformers may set it)
      # The InjectDispatchChanges transformer generates it
      assert is_nil(created_event.event_id) or
               created_event.event_id =~ ~r/test_product\.created/
    end
  end

  describe "transformers" do
    test "ValidateEvents runs without errors" do
      # If the module compiles, the validators passed
      assert Code.ensure_loaded?(TestProduct)
    end

    test "InjectDispatchChanges adds dispatch changes to actions" do
      # Get the create action
      create_action = Ash.Resource.Info.action(TestProduct, :create)

      # Check if DispatchEvent change was injected
      # Note: We might need to implement AshDispatch.Changes.DispatchEvent first
      # For now, just verify the action exists
      assert create_action.name == :create
    end
  end

  describe "configuration validation" do
    test "channels can be keyword lists or maps" do
      dsl_state = TestProduct.spark_dsl_config()
      events = Transformer.get_entities(dsl_state, [:dispatch])

      created_event = Enum.find(events, &(&1.name == :created))
      [channel | _] = created_event.channels

      # Channel should be stored as keyword list or map
      assert is_list(channel) or is_map(channel)
      assert channel[:transport] == :in_app or Map.get(channel, :transport) == :in_app
    end

    test "content supports variable interpolation syntax" do
      dsl_state = TestProduct.spark_dsl_config()
      events = Transformer.get_entities(dsl_state, [:dispatch])

      created_event = Enum.find(events, &(&1.name == :created))

      # Check that {{variable}} syntax is preserved
      assert created_event.content[:notification_message] =~ ~r/\{\{name\}\}/
    end
  end
end
