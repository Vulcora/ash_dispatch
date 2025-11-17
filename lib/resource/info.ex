defmodule AshDispatch.Resource.Info do
  @moduledoc """
  Introspection helpers for AshDispatch.Resource.

  Provides functions to query event configurations from resources at runtime.

  ## Usage

      # Get all events for a resource
      events = AshDispatch.Resource.Info.events(MyApp.Orders.ProductOrder)

      # Get a specific event by name
      event = AshDispatch.Resource.Info.event(MyApp.Orders.ProductOrder, :created)

      # Get event options
      event_id = AshDispatch.Resource.Info.event_id(event)
      trigger_on = AshDispatch.Resource.Info.trigger_on(event)
      channels = AshDispatch.Resource.Info.channels(event)

  ## Generated Functions

  This module uses `Spark.InfoGenerator` to automatically generate helper functions
  for querying the `dispatch` section and its entities.

  **Resource-level:**
  - `events(resource)` - Returns all events defined in the resource

  **Event entity getters:**
  - `name(event)` - Get event name
  - `trigger_on(event)` - Get action names that trigger this event
  - `module(event)` - Get callback module (if any)
  - `event_id(event)` - Get event ID
  - `domain(event)` - Get event domain
  - `load(event)` - Get relationships to preload
  - `channels(event)` - Get channel configurations
  - `content(event)` - Get content configuration
  - `metadata(event)` - Get metadata configuration

  ## Examples

      # Find events triggered by specific action
      iex> events = AshDispatch.Resource.Info.events(ProductOrder)
      iex> Enum.filter(events, fn event ->
      ...>   :create in List.wrap(AshDispatch.Resource.Info.trigger_on(event))
      ...> end)
      [%AshDispatch.Resource.Dsl.Event{name: :created, ...}]

      # Get all event IDs for a resource
      iex> events = AshDispatch.Resource.Info.events(ProductOrder)
      iex> Enum.map(events, &AshDispatch.Resource.Info.event_id/1)
      ["product_order.created", "product_order.cancelled"]

      # Check if event has callback module
      iex> event = AshDispatch.Resource.Info.event(ProductOrder, :created)
      iex> if AshDispatch.Resource.Info.module(event) do
      ...>   "Uses callback module"
      ...> else
      ...>   "Uses inline config"
      ...> end
      "Uses inline config"
  """

  use Spark.InfoGenerator,
    sections: [:dispatch],
    extension: AshDispatch.Resource

  @doc """
  Get all events defined in a resource.

  ## Parameters

  - `resource` - The resource module

  ## Returns

  List of `%AshDispatch.Resource.Dsl.Event{}` structs

  ## Examples

      iex> AshDispatch.Resource.Info.events(ProductOrder)
      [%AshDispatch.Resource.Dsl.Event{name: :created, ...}]
  """
  def events(resource) do
    Spark.Dsl.Extension.get_entities(resource, [:dispatch])
  end

  @doc """
  Get a specific event by name.

  ## Parameters

  - `resource` - The resource module
  - `name` - The event name (atom)

  ## Returns

  - `%AshDispatch.Resource.Dsl.Event{}` if found
  - `nil` if not found

  ## Examples

      iex> AshDispatch.Resource.Info.event(ProductOrder, :created)
      %AshDispatch.Resource.Dsl.Event{name: :created, ...}

      iex> AshDispatch.Resource.Info.event(ProductOrder, :nonexistent)
      nil
  """
  def event(resource, name) do
    resource
    |> events()
    |> Enum.find(&(&1.name == name))
  end

  @doc """
  Get all events that trigger on a specific action.

  ## Parameters

  - `resource` - The resource module
  - `action_name` - The action name (atom)

  ## Returns

  List of `%AshDispatch.Resource.Dsl.Event{}` structs

  ## Examples

      iex> AshDispatch.Resource.Info.events_for_action(ProductOrder, :create)
      [%AshDispatch.Resource.Dsl.Event{name: :created, trigger_on: :create}]

      iex> AshDispatch.Resource.Info.events_for_action(ProductOrder, :update)
      []
  """
  def events_for_action(resource, action_name) do
    resource
    |> events()
    |> Enum.filter(fn event ->
      trigger_on = event.trigger_on

      cond do
        is_atom(trigger_on) -> trigger_on == action_name
        is_list(trigger_on) -> action_name in trigger_on
        true -> false
      end
    end)
  end

  @doc """
  Check if a resource has the AshDispatch.Resource extension.

  ## Parameters

  - `resource` - The resource module

  ## Returns

  - `true` if resource uses AshDispatch.Resource
  - `false` otherwise

  ## Examples

      iex> AshDispatch.Resource.Info.dispatch_enabled?(ProductOrder)
      true

      iex> AshDispatch.Resource.Info.dispatch_enabled?(SomeOtherResource)
      false
  """
  def dispatch_enabled?(resource) do
    AshDispatch.Resource in Spark.extensions(resource)
  end

  @doc """
  Get all event IDs for a resource.

  ## Parameters

  - `resource` - The resource module

  ## Returns

  List of event ID strings

  ## Examples

      iex> AshDispatch.Resource.Info.event_ids(ProductOrder)
      ["product_order.created", "product_order.cancelled", "product_order.shipped"]
  """
  def event_ids(resource) do
    resource
    |> events()
    |> Enum.map(& &1.event_id)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Get all events that use callback modules.

  ## Parameters

  - `resource` - The resource module

  ## Returns

  List of `%AshDispatch.Resource.Dsl.Event{}` structs that have a module defined

  ## Examples

      iex> AshDispatch.Resource.Info.events_with_modules(ProductOrder)
      [%AshDispatch.Resource.Dsl.Event{name: :complex_event, module: MyApp.Events.Complex}]
  """
  def events_with_modules(resource) do
    resource
    |> events()
    |> Enum.filter(& &1.module)
  end

  @doc """
  Get all events that use inline configuration.

  ## Parameters

  - `resource` - The resource module

  ## Returns

  List of `%AshDispatch.Resource.Dsl.Event{}` structs that use inline config

  ## Examples

      iex> AshDispatch.Resource.Info.inline_events(ProductOrder)
      [%AshDispatch.Resource.Dsl.Event{name: :created, module: nil, channels: [...]}]
  """
  def inline_events(resource) do
    resource
    |> events()
    |> Enum.reject(& &1.module)
  end

  @doc """
  Count total events for a resource.

  ## Parameters

  - `resource` - The resource module

  ## Returns

  Integer count of events

  ## Examples

      iex> AshDispatch.Resource.Info.event_count(ProductOrder)
      3
  """
  def event_count(resource) do
    resource
    |> events()
    |> length()
  end
end
