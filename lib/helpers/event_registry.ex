defmodule AshDispatch.EventRegistry do
  @moduledoc """
  Auto-discovery registry for event modules.

  This module eliminates the need for manual `event_modules` configuration by
  automatically discovering events from Ash domains at runtime.

  ## How It Works

  1. Scans all configured Ash domains for the given `otp_app`
  2. Finds resources with `AshDispatch.Resource` extension
  3. Reads event definitions from the `dispatch` DSL section
  4. Returns event information including any associated modules

  ## Usage

  Instead of manually configuring:

      # OLD - Manual config (no longer needed!)
      config :ash_dispatch, :event_modules, [
        {"order.created", MyApp.Events.OrderCreated},
        {"ticket.assigned", MyApp.Events.TicketAssigned}
      ]

  Events are now auto-discovered:

      # Get all event modules (for backward compatibility)
      EventRegistry.get_event_modules()

      # Find a specific event
      {:ok, event} = EventRegistry.find_event("order.created")

      # Find module for an event
      {:ok, module} = EventRegistry.find_module("order.created")

  ## Configuration

  The registry uses the `:otp_app` config to know which app's domains to scan:

      config :ash_dispatch, :otp_app, :my_app

  And the app must have domains configured:

      config :my_app, :ash_domains, [MyApp.Orders, MyApp.Tickets]
  """

  alias AshDispatch.Config
  alias AshDispatch.Naming

  require Logger

  @doc """
  Get all event modules in the format `[{event_id, module}, ...]`.

  This provides backward compatibility with the old `:event_modules` config format.
  Only returns events that have an associated module (explicit or generated).

  Uses the configured `:otp_app` to determine which domains to scan.
  """
  @spec get_event_modules() :: [{String.t(), module()}]
  def get_event_modules do
    otp_app = Config.otp_app()

    if otp_app do
      event_modules(otp_app)
    else
      # Fall back to legacy config for backward compatibility
      Config.event_modules()
    end
  end

  @doc """
  Get all event modules for a specific otp_app.

  Returns a list of `{event_id, module}` tuples for events that have modules.
  Events without modules (pure inline DSL) are excluded.
  """
  @spec event_modules(atom()) :: [{String.t(), module()}]
  def event_modules(otp_app) do
    otp_app
    |> all_events()
    |> Enum.filter(fn event -> event.module != nil end)
    |> Enum.map(fn event -> {event.event_id, event.module} end)
  end

  @doc """
  Find an event by its event_id.

  Returns `{:ok, event_info}` or `{:error, :not_found}`.
  """
  @spec find_event(String.t(), atom() | nil) :: {:ok, map()} | {:error, :not_found}
  def find_event(event_id, otp_app \\ nil) do
    otp_app = otp_app || Config.otp_app()

    if otp_app do
      case Enum.find(all_events(otp_app), &(&1.event_id == event_id)) do
        nil -> {:error, :not_found}
        event -> {:ok, event}
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Find the module for an event by its event_id.

  Returns `{:ok, module}`, `{:error, :no_module}` if event exists but has no module,
  or `{:error, :not_found}` if event doesn't exist.
  """
  @spec find_module(String.t(), atom() | nil) ::
          {:ok, module()} | {:error, :not_found | :no_module}
  def find_module(event_id, otp_app \\ nil) do
    case find_event(event_id, otp_app) do
      {:ok, %{module: nil}} -> {:error, :no_module}
      {:ok, %{module: module}} -> {:ok, module}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get all events from all resources in the configured domains.

  Returns a list of event info maps with:
  - `:event_id` - The event identifier (e.g., "order.created")
  - `:name` - The event name atom (e.g., :created)
  - `:module` - The event module (if any)
  - `:resource` - The resource module that defines this event
  - `:channels` - Channel configurations from DSL
  - `:content` - Content configuration from DSL
  - `:metadata` - Metadata configuration from DSL
  """
  @spec all_events(atom()) :: [map()]
  def all_events(otp_app) do
    domains = get_domains(otp_app)

    domains
    |> Enum.flat_map(&get_domain_resources/1)
    |> Enum.filter(&uses_ash_dispatch?/1)
    |> Enum.flat_map(&extract_events/1)
  end

  # Private helpers

  defp get_domains(otp_app) do
    # Priority:
    # 1. Standard Ash :ash_domains config (uses same config as Ash)
    # 2. Fallback to :ash_dispatch :domains config (for explicit override)
    case Application.get_env(otp_app, :ash_domains, []) do
      [] -> Config.domains()
      domains -> domains
    end
  end

  defp get_domain_resources(domain) do
    Ash.Domain.Info.resources(domain)
  rescue
    _ -> []
  end

  defp uses_ash_dispatch?(resource) do
    AshDispatch.Resource in Spark.extensions(resource)
  rescue
    _ -> false
  end

  defp extract_events(resource) do
    # Get events from the dispatch section
    events = Spark.Dsl.Extension.get_entities(resource, [:dispatch])

    events
    |> Enum.filter(&is_event_entity?/1)
    |> Enum.map(fn event ->
      event_id = event.event_id || Naming.event_id(resource, event.name)

      %{
        event_id: event_id,
        name: event.name,
        module: resolve_module(event, resource),
        resource: resource,
        channels: event.channels,
        content: event.content,
        metadata: event.metadata,
        trigger_on: event.trigger_on
      }
    end)
  rescue
    error ->
      Logger.warning(
        "[EventRegistry] Failed to extract events from #{inspect(resource)}: #{inspect(error)}"
      )

      []
  end

  # Check if entity is an event (not AudiencePrefix, AudienceOverride, etc.)
  defp is_event_entity?(%{__struct__: struct}) do
    struct == AshDispatch.Resource.Dsl.Event
  end

  defp is_event_entity?(_), do: false

  # Resolve module - explicit module from DSL takes precedence
  defp resolve_module(event, resource) do
    case event.module do
      module when not is_nil(module) ->
        # Explicit module in DSL
        module

      nil ->
        # Try to find auto-generated module using Naming convention
        domain_name = Naming.domain_name(resource)
        derived_module = Naming.event_module(resource, domain_name, event.name)

        if Code.ensure_loaded?(derived_module) do
          derived_module
        else
          nil
        end
    end
  end
end
