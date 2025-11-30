defmodule AshDispatch.Introspection do
  @moduledoc """
  Central introspection module for discovering all AshDispatch events.

  Provides a unified view of events from both inline DSL (defined in resources)
  and module-based events (standalone event modules).

  ## Usage

      # Get all events in the application
      events = AshDispatch.Introspection.all_events(:my_app)

      # Get resources with dispatch enabled
      resources = AshDispatch.Introspection.dispatch_resources(:my_app)

      # Find missing templates
      missing = AshDispatch.Introspection.all_missing_templates(:my_app)
  """

  alias AshDispatch.Naming
  alias AshDispatch.Resource.Info, as: ResourceInfo

  @type event_info :: %{
          source: :inline | :module,
          event_id: String.t(),
          name: atom() | nil,
          resource: module() | nil,
          module: module() | nil,
          domain: atom() | nil,
          channels: list(map()),
          content: map() | nil,
          metadata: map() | nil
        }

  @type missing_template :: %{
          event_id: String.t(),
          path: String.t(),
          filename: String.t(),
          format: :html | :text,
          transport: atom(),
          variant: atom() | nil
        }

  # ============================================================================
  # Event Discovery
  # ============================================================================

  @doc """
  Returns all events across all dispatch-enabled resources and event modules.

  Combines inline DSL events (from resources) and module-based events into
  a unified list.

  ## Parameters

  - `otp_app` - The OTP application name

  ## Returns

  List of event info maps with unified structure
  """
  @spec all_events(atom()) :: [event_info()]
  def all_events(otp_app) do
    # Events are discovered from inline DSL in resources
    # Each inline event may reference an event module for callbacks
    discover_inline_events(otp_app)
  end

  @doc """
  Returns all resources that have the AshDispatch.Resource extension.

  ## Parameters

  - `otp_app` - The OTP application name

  ## Returns

  List of resource modules with dispatch enabled
  """
  @spec dispatch_resources(atom()) :: [module()]
  def dispatch_resources(otp_app) do
    otp_app
    |> domains()
    |> Enum.flat_map(&safe_resources/1)
    |> Enum.filter(&ResourceInfo.dispatch_enabled?/1)
  end

  # ============================================================================
  # Template Detection
  # ============================================================================

  @doc """
  Finds all missing templates for events in the application.

  Checks inline DSL events for missing template files based on their
  channel definitions.

  ## Parameters

  - `otp_app` - The OTP application name

  ## Returns

  List of missing template info maps
  """
  @spec all_missing_templates(atom()) :: [missing_template()]
  def all_missing_templates(otp_app) do
    otp_app
    |> all_events()
    |> Enum.flat_map(&missing_templates(&1, otp_app))
  end

  @doc """
  Calculates required templates for an event based on its channels.

  ## Parameters

  - `event_info` - Event info map from `all_events/1`

  ## Returns

  List of required template specs
  """
  @spec required_templates(event_info()) :: [map()]
  def required_templates(event_info) do
    event_info.channels
    |> Enum.flat_map(&templates_for_channel/1)
    |> Enum.uniq_by(& &1.filename)
  end

  @doc """
  Finds missing templates for a specific event.

  ## Parameters

  - `event_info` - Event info map
  - `otp_app` - The OTP application name

  ## Returns

  List of missing template info maps
  """
  @spec missing_templates(event_info(), atom()) :: [missing_template()]
  def missing_templates(event_info, otp_app) do
    template_dir = template_directory(event_info, otp_app)

    event_info
    |> required_templates()
    |> Enum.filter(fn template ->
      path = Path.join(template_dir, template.filename)
      not File.exists?(path)
    end)
    |> Enum.map(fn template ->
      %{
        event_id: event_info.event_id,
        path: Path.join(template_dir, template.filename),
        filename: template.filename,
        format: template.format,
        transport: template.transport,
        variant: template.variant
      }
    end)
  end

  @doc """
  Returns the template directory path for an event.

  Delegates to `AshDispatch.TemplateResolver.resolve_template_directory/2` which is
  the single source of truth for template path resolution.

  ## Resolution Order

  1. **Explicit module**: If event has `module:` option, use module-based path
  2. **Derived module**: Use `{App}.{Domain}.Events.{EventName}.Event` path

  Events are expected to have modules (either explicit or generated via `mix ash_dispatch.gen`).
  Templates live in `{module_dir}/templates/`.

  ## Parameters

  - `event_info` - Event info map
  - `otp_app` - The OTP application name

  ## Returns

  Path string to the template directory
  """
  @spec template_directory(event_info(), atom()) :: String.t()
  def template_directory(event_info, otp_app) do
    AshDispatch.TemplateResolver.resolve_template_directory(event_info, otp_app)
  end

  # ============================================================================
  # Event Module Detection
  # ============================================================================

  @doc """
  Finds missing event modules for inline DSL events.

  Returns modules for ALL events that don't have a user-provided `module:` option.
  Generated modules provide:
  - Template directory for email/sms transports
  - Fallback callbacks (recipients, content, etc.)
  - A place to add custom logic later

  The system uses a **hybrid approach**: DSL configuration takes precedence,
  but the generated module provides fallbacks for anything not specified in DSL.

  ## Parameters

  - `otp_app` - The OTP application name

  ## Returns

  List of missing module info maps
  """
  @spec missing_event_modules(atom()) :: [map()]
  def missing_event_modules(otp_app) do
    otp_app
    |> all_events()
    |> Enum.filter(&(&1.source == :inline))
    # Skip events that already have a user-provided module (override)
    |> Enum.reject(&(&1.module != nil))
    |> Enum.map(fn event_info ->
      module_name = derive_module_name(event_info, otp_app)
      module_path = module_path_from_name(module_name, otp_app)

      %{
        event_id: event_info.event_id,
        module_name: module_name,
        module_path: module_path,
        exists: Code.ensure_loaded?(module_name),
        event_info: event_info
      }
    end)
    |> Enum.reject(& &1.exists)
  end

  @doc """
  Derives the expected module name for an event.

  Uses otp_app as the module prefix (e.g., :my_app → MyApp) and derives
  the domain from either the event_info or the resource.

  Used by both the generator (to create modules) and the transformer
  (to auto-connect generated modules).

  ## Parameters

  - `event_info` - Event info map or struct with :domain, :name, and :resource keys
  - `otp_app` - The OTP application name (used for module prefix)

  ## Returns

  Module name atom (e.g., MyApp.Orders.Events.Created.Event)
  """
  @spec derive_module_name(map(), atom()) :: module()
  def derive_module_name(event_info, otp_app) do
    domain = event_info[:domain] || Naming.domain_name(event_info[:resource])
    Naming.event_module_from_otp_app(otp_app, domain, event_info[:name])
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp discover_inline_events(otp_app) do
    otp_app
    |> dispatch_resources()
    |> Enum.flat_map(fn resource ->
      resource
      |> ResourceInfo.events()
      |> Enum.map(&normalize_inline_event(&1, resource, otp_app))
    end)
  end

  defp normalize_inline_event(event, resource, _otp_app) do
    # Use Naming for consistent derivation
    resource_name = Naming.resource_name(resource)
    event_id = event.event_id || Naming.event_id(resource, event.name)
    domain = Naming.domain_name(resource)

    %{
      source: :inline,
      event_id: event_id,
      name: event.name,
      resource: resource,
      resource_name: resource_name,
      module: event.module,
      domain: domain && String.to_atom(domain),
      channels: normalize_channels(event.channels || []),
      content: event.content,
      metadata: event.metadata,
      trigger_on: event.trigger_on,
      data_key: event.data_key
    }
  end

  defp normalize_channels(channels) when is_list(channels) do
    Enum.map(channels, fn channel ->
      case channel do
        %{transport: _} = ch ->
          Map.take(ch, [:transport, :audience, :variant, :policy, :content, :metadata])

        [_ | _] = opts ->
          %{
            transport: Keyword.get(opts, :transport),
            audience: Keyword.get(opts, :audience),
            variant: Keyword.get(opts, :variant),
            policy: Keyword.get(opts, :policy),
            content: Keyword.get(opts, :content),
            metadata: Keyword.get(opts, :metadata)
          }

        _ ->
          %{transport: nil, audience: nil, variant: nil}
      end
    end)
  end

  defp normalize_channels(_), do: []

  defp templates_for_channel(%{transport: transport, variant: variant}) do
    # Templates are determined by transport type and variant presence:
    # - If variant is set: ONLY variant-specific templates (e.g., email.admin.html.heex)
    # - If no variant: base templates (e.g., email.html.heex)
    case {transport, variant} do
      {:email, nil} ->
        # No variant - need base templates
        [
          %{transport: :email, format: :html, filename: "email.html.heex", variant: nil},
          %{transport: :email, format: :text, filename: "email.text.eex", variant: nil}
        ]

      {:email, variant} when not is_nil(variant) ->
        # Has variant - only need variant-specific templates
        variant_str = to_string(variant)

        [
          %{
            transport: :email,
            format: :html,
            filename: "email.#{variant_str}.html.heex",
            variant: variant
          },
          %{
            transport: :email,
            format: :text,
            filename: "email.#{variant_str}.text.eex",
            variant: variant
          }
        ]

      {:sms, _} ->
        [%{transport: :sms, format: :text, filename: "sms.text.eex", variant: nil}]

      # in_app, webhook, discord, slack don't require templates
      _ ->
        []
    end
  end

  defp templates_for_channel(_), do: []

  defp module_path_from_name(module_name, otp_app) do
    parts =
      module_name
      |> Module.split()
      |> Enum.map(&Macro.underscore/1)

    # Replace app prefix with lib/{app}
    [_app | rest] = parts
    Path.join(["lib", to_string(otp_app) | rest]) <> ".ex"
  end

  defp domains(otp_app) do
    Application.get_env(otp_app, :ash_domains, [])
  end

  defp safe_resources(domain) do
    if Code.ensure_loaded?(domain) do
      case Ash.Domain.Info.resources(domain) do
        resources when is_list(resources) -> resources
        _ -> []
      end
    else
      []
    end
  rescue
    _ -> []
  end
end
