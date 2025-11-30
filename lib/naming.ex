defmodule AshDispatch.Naming do
  @moduledoc """
  Central module for all AshDispatch naming conventions.

  This module is the **single source of truth** for deriving names from resources,
  events, and channels. All other modules should delegate to these functions
  to ensure consistent naming across the library.

  ## Resource & Event Naming

  Derive identifiers and module names from Ash resources:

      iex> Naming.event_id(MyApp.Orders.ProductOrder, :created)
      "product_order.created"

      iex> Naming.domain_name(MyApp.Orders.ProductOrder)
      "orders"

      iex> Naming.resource_name(MyApp.Orders.ProductOrder)
      "product_order"

      iex> Naming.data_key(MyApp.Orders.ProductOrder)
      :product_order

      iex> Naming.event_module(MyApp.Orders.ProductOrder, "orders", :created)
      MyApp.Orders.Events.Created.Event

  ## Channel Naming (Filenames & Labels)

  Handles the logic for combining transport, audience, and variant into:
  - Filenames (e.g., `email.user.html`, `email.admin.summary.txt`)
  - Display labels (e.g., "email (user)", "email (admin, summary)")

  ### Deduplication Rule

  When variant equals audience (e.g., `audience: :admin, variant: "admin"`),
  the variant is omitted to avoid redundant names like "email.admin.admin.html".

  ## Examples

      iex> Naming.filename("email", :user, nil, "html")
      "email.user.html"

      iex> Naming.filename("email", :admin, "admin", "html")
      "email.admin.html"  # variant omitted (matches audience)

      iex> Naming.filename("email", :admin, "summary", "html")
      "email.admin.summary.html"

      iex> Naming.label(:email, :user, nil)
      "email (user)"

      iex> Naming.label(:email, :admin, "admin")
      "email (admin)"  # variant omitted (matches audience)

      iex> Naming.label(:email, :admin, "summary")
      "email (admin, summary)"
  """

  # ===========================================================================
  # Resource & Event Naming
  # ===========================================================================

  @doc """
  Generate an event ID from a resource module and event name.

  Uses the resource name (last module segment) to avoid collisions when
  multiple resources in the same domain have common event names.

  ## Examples

      iex> Naming.event_id(MyApp.Orders.ProductOrder, :created)
      "product_order.created"

      iex> Naming.event_id(MyApp.Accounts.User, :password_reset)
      "user.password_reset"
  """
  @spec event_id(module(), atom()) :: String.t()
  def event_id(resource, event_name) when is_atom(resource) and is_atom(event_name) do
    "#{resource_name(resource)}.#{event_name}"
  end

  def event_id(_resource, event_name), do: "unknown.#{event_name}"

  @doc """
  Extract the domain name from a resource module.

  Takes the second-to-last module segment and converts to snake_case.

  ## Examples

      iex> Naming.domain_name(MyApp.Orders.ProductOrder)
      "orders"

      iex> Naming.domain_name(MyApp.Accounts.User)
      "accounts"
  """
  @spec domain_name(module()) :: String.t() | nil
  def domain_name(resource) when is_atom(resource) do
    module_parts = Module.split(resource)

    case length(module_parts) do
      n when n >= 2 ->
        module_parts
        |> Enum.at(-2)
        |> Macro.underscore()

      _ ->
        nil
    end
  end

  def domain_name(_), do: nil

  @doc """
  Extract the resource name from a resource module.

  Takes the last module segment and converts to snake_case.

  ## Examples

      iex> Naming.resource_name(MyApp.Orders.ProductOrder)
      "product_order"

      iex> Naming.resource_name(MyApp.Accounts.User)
      "user"
  """
  @spec resource_name(module()) :: String.t() | nil
  def resource_name(resource) when is_atom(resource) do
    resource
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  def resource_name(_), do: nil

  @doc """
  Derive the data_key from a resource module.

  Converts the resource name to a snake_case atom, used as the key
  in context.data for storing the primary resource.

  ## Examples

      iex> Naming.data_key(MyApp.Orders.ProductOrder)
      :product_order

      iex> Naming.data_key(MyApp.Accounts.User)
      :user
  """
  @spec data_key(module()) :: atom() | nil
  def data_key(resource) when is_atom(resource) do
    resource
    |> resource_name()
    |> String.to_atom()
  end

  def data_key(_), do: nil

  @doc """
  Extract the app module name from a resource.

  Takes the first module segment.

  ## Examples

      iex> Naming.app_module(MyApp.Orders.ProductOrder)
      "MyApp"
  """
  @spec app_module(module()) :: String.t() | nil
  def app_module(resource) when is_atom(resource) do
    resource
    |> Module.split()
    |> List.first()
  end

  def app_module(_), do: nil

  @doc """
  Derive the expected event module name from resource and event info.

  Convention: `{App}.{Domain}.Events.{EventName}.Event`

  ## Examples

      iex> Naming.event_module(MyApp.Orders.ProductOrder, "orders", :created)
      MyApp.Orders.Events.Created.Event

      iex> Naming.event_module(MyApp.Accounts.User, "accounts", :password_reset)
      MyApp.Accounts.Events.PasswordReset.Event
  """
  @spec event_module(module(), String.t() | nil, atom()) :: module()
  def event_module(resource, domain_name, event_name)
      when is_atom(resource) and is_atom(event_name) do
    app = app_module(resource)
    domain = domain_name |> to_string() |> Macro.camelize()
    event = event_name |> to_string() |> Macro.camelize()

    Module.concat([app, domain, "Events", event, "Event"])
  end

  @doc """
  Derive the event module from a resource (auto-deriving domain).

  Convenience function that combines `domain_name/1` and `event_module/3`.

  ## Examples

      iex> Naming.event_module_for_resource(MyApp.Orders.ProductOrder, :created)
      MyApp.Orders.Events.Created.Event
  """
  @spec event_module_for_resource(module(), atom()) :: module()
  def event_module_for_resource(resource, event_name) when is_atom(resource) do
    domain = domain_name(resource)
    event_module(resource, domain, event_name)
  end

  @doc """
  Derive the event module from otp_app and domain/event names.

  Used when the app prefix should come from otp_app rather than a resource module.
  This is the preferred approach for generated modules since they should live
  in the user's app namespace.

  ## Examples

      iex> Naming.event_module_from_otp_app(:my_app, :orders, :created)
      MyApp.Orders.Events.Created.Event

      iex> Naming.event_module_from_otp_app(:acme_support, :tickets, :assigned)
      AcmeSupport.Tickets.Events.Assigned.Event
  """
  @spec event_module_from_otp_app(atom(), atom() | String.t(), atom()) :: module()
  def event_module_from_otp_app(otp_app, domain_name, event_name)
      when is_atom(otp_app) and is_atom(event_name) do
    app = otp_app |> to_string() |> Macro.camelize()
    domain = domain_name |> to_string() |> Macro.camelize()
    event = event_name |> to_string() |> Macro.camelize()

    Module.concat([app, domain, "Events", event, "Event"])
  end

  @doc """
  Derive the module directory path from a module name.

  Used for locating template files relative to the event module.

  ## Examples

      iex> Naming.module_directory(MyApp.Orders.Events.Created.Event)
      "lib/my_app/orders/events/created"
  """
  @spec module_directory(module()) :: String.t()
  def module_directory(module) when is_atom(module) do
    module
    |> Module.split()
    |> Enum.map(&Macro.underscore/1)
    # Remove "Event" suffix from path
    |> Enum.drop(-1)
    |> then(fn parts -> Path.join(["lib" | parts]) end)
  end

  @doc """
  Derive the template directory path from an event module.

  ## Examples

      iex> Naming.template_directory(MyApp.Orders.Events.Created.Event)
      "lib/my_app/orders/events/created/templates"
  """
  @spec template_directory(module()) :: String.t()
  def template_directory(module) when is_atom(module) do
    Path.join(module_directory(module), "templates")
  end

  # ===========================================================================
  # Channel Naming (Filenames & Labels)
  # ===========================================================================

  @doc """
  Build a filename from channel properties.

  ## Parameters

  - `base` - Base name, typically the transport (e.g., "email")
  - `audience` - Target audience atom (e.g., :user, :admin)
  - `variant` - Optional variant string or atom (e.g., "summary", :admin)
  - `extension` - File extension without dot (e.g., "html", "txt")

  ## Returns

  Filename string like "email.user.html" or "email.admin.summary.txt"
  """
  def filename(base, audience, variant, extension) do
    parts = build_parts(base, audience, variant)
    Enum.join(parts, ".") <> ".#{extension}"
  end

  @doc """
  Build a display label from channel properties.

  ## Parameters

  - `transport` - Transport type atom (e.g., :email, :sms)
  - `audience` - Target audience atom (e.g., :user, :admin)
  - `variant` - Optional variant string or atom

  ## Returns

  Label string like "email (user)" or "email (admin, summary)"
  """
  def label(transport, audience, variant) do
    transport_str = to_string(transport || :email)
    audience_str = to_string(audience || :user)

    qualifier_parts = build_qualifier_parts(audience_str, variant)

    "#{transport_str} (#{Enum.join(qualifier_parts, ", ")})"
  end

  @doc """
  Check if variant should be included (not redundant with audience).

  Returns true if variant is present AND different from audience.
  """
  def include_variant?(audience, variant) do
    variant_str = if variant, do: to_string(variant), else: nil
    audience_str = if audience, do: to_string(audience), else: nil

    variant_str != nil && variant_str != audience_str
  end

  @doc """
  Get the effective variant parts to display/include.

  Returns a list of parts after audience, excluding redundant variant.
  """
  def variant_parts(audience, variant) do
    if include_variant?(audience, variant) do
      [to_string(variant)]
    else
      []
    end
  end

  # Build filename parts: [base, audience, variant?]
  defp build_parts(base, audience, variant) do
    parts = [base]

    # Always include audience
    parts =
      if audience do
        parts ++ [to_string(audience)]
      else
        parts
      end

    # Include variant only if different from audience
    parts ++ variant_parts(audience, variant)
  end

  # Build qualifier parts for label: [audience, variant?]
  defp build_qualifier_parts(audience_str, variant) do
    parts = [audience_str]
    variant_str = if variant, do: to_string(variant), else: nil

    # Include variant only if different from audience
    if variant_str && variant_str != audience_str do
      parts ++ [variant_str]
    else
      parts
    end
  end
end
