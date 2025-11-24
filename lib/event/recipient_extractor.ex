defmodule AshDispatch.Event.RecipientExtractor do
  @moduledoc """
  Extracts recipient identifiers and names from recipient structs using cascading configuration.

  > **For usage examples and complete guide**, see the [Recipient Field Extraction](recipient-extractor.html) topic guide.

  ## Configuration Resolution Order

  The extractor uses a cascading resolution strategy (most specific to least specific):

  1. **Event DSL override** - Configured directly in the event definition
  2. **Audience + Transport config** - Audience-specific transport configuration
  3. **Transport config** - Transport-specific configuration
  4. **Generic default** - Single default for all transports
  5. **Error** - No configuration found

  ## Configuration Structure

      # config/config.exs
      config :ash_dispatch,
        recipient_fields: [
          # Per-transport defaults (transport-first structure)
          email: [
            identifier: :email,
            name: [:display_name, :name, :contact_person, :full_name]  # fallback chain
          ],
          discord: [
            identifier: :discord_id,
            name: [:app_username, :display_name, :name]
          ],
          in_app: [
            identifier: :id,
            name: [:display_name, :name]
          ],
          sms: [
            identifier: :mobile_phone,
            name: [:first_name, :name]
          ],

          # Per-audience overrides (optional)
          audiences: [
            admin: [
              email: [name: :full_name]  # Admins show full name in emails
            ],
            customer: [
              email: [
                identifier: :contact_email,
                name: [:company_name, :contact_person]
              ]
            ]
          ]
        ]

  ## Field Extraction Formats

  The extractor supports multiple field specification formats:

  - `:field_name` - Direct atom field access
  - `{:field, :field_name}` - Explicit field tuple
  - `{:field, [:nested, :path]}` - Nested field access via `get_in/2`
  - `{:string_field, "key"}` - String key access for JSON data
  - `&Module.function/1` - Custom extraction function
  - `nil` - No field (e.g., webhooks don't need names)

  ## Examples

      # Extract with generic defaults
      RecipientExtractor.extract_identifier(user, :email, :user)
      # → Uses config[:recipient_fields][:identifier] → :email

      # Extract with transport override
      RecipientExtractor.extract_identifier(user, :sms, :user)
      # → Uses config[:recipient_fields][:sms][:identifier] → :mobile_phone

      # Extract with audience override
      RecipientExtractor.extract_name(admin, :email, :admin)
      # → Uses config[:recipient_fields][:audiences][:admin][:name] → :full_name

      # Extract with nested field
      RecipientExtractor.extract_identifier(%{contact: %{email: "..."}}, :email, :user)
      # With config: identifier: {:field, [:contact, :email]}
      # → "..."

      # Extract with custom function
      RecipientExtractor.extract_identifier(lead, :email, :lead)
      # With config: identifier: &MyApp.extract_lead_email/1
      # → Calls MyApp.extract_lead_email(lead)
  """

  require Logger

  @doc """
  Extracts the recipient identifier (email, phone, webhook URL, etc.) based on transport and audience.

  ## Parameters

  - `recipient` - The recipient struct/map to extract from
  - `transport` - The transport type (`:email`, `:sms`, `:in_app`, etc.)
  - `audience` - The audience type (`:user`, `:admin`, `:lead`, etc.)
  - `event_config` - Optional event-specific configuration (from DSL)

  ## Returns

  The extracted identifier string, or raises an error if extraction fails.

  ## Examples

      iex> user = %User{email: "user@example.com", phone: "555-1234"}
      iex> RecipientExtractor.extract_identifier(user, :email, :user)
      "user@example.com"

      iex> RecipientExtractor.extract_identifier(user, :sms, :user)
      "555-1234"
  """
  def extract_identifier(recipient, transport, audience, event_config \\ nil) do
    field = get_identifier_field(transport, audience, event_config)

    if is_nil(field) do
      raise_missing_config_error(transport, audience, :identifier)
    end

    result = extract_field(recipient, field)

    if is_nil(result) do
      raise_extraction_error(recipient, field, transport, audience, :identifier)
    end

    result
  end

  @doc """
  Extracts the recipient display name based on transport and audience.

  ## Parameters

  - `recipient` - The recipient struct/map to extract from
  - `transport` - The transport type (`:email`, `:sms`, `:in_app`, etc.)
  - `audience` - The audience type (`:user`, `:admin`, `:lead`, etc.)
  - `event_config` - Optional event-specific configuration (from DSL)

  ## Returns

  The extracted name string, or `nil` if no name is configured/available.

  ## Examples

      iex> user = %User{email: "user@example.com", contact_person: "John Doe"}
      iex> RecipientExtractor.extract_name(user, :email, :user)
      "John Doe"
  """
  def extract_name(recipient, transport, audience, event_config \\ nil) do
    field = get_name_field(transport, audience, event_config)

    if is_nil(field) do
      # Name is optional - return nil if not configured
      nil
    else
      extract_field(recipient, field)
    end
  end

  # Cascading resolution for identifier field
  defp get_identifier_field(transport, audience, event_config) do
    # 1. Event DSL override (most specific)
    # 2. Audience + Transport config
    # 3. Transport config
    # 4. Generic default (least specific)
    get_in(event_config, [:recipient, transport, :identifier]) ||
      get_audience_transport_field(audience, transport, :identifier) ||
      get_transport_field(transport, :identifier) ||
      get_generic_field(:identifier)
  end

  # Cascading resolution for name field
  defp get_name_field(transport, audience, event_config) do
    get_in(event_config, [:recipient, transport, :name]) ||
      get_audience_transport_field(audience, transport, :name) ||
      get_transport_field(transport, :name) ||
      get_generic_field(:name)
  end

  # Get field from audience-specific config (transport-first)
  defp get_audience_transport_field(audience, transport, field_type) do
    config = Application.get_env(:ash_dispatch, :recipient_fields, [])
    get_in(config, [:audiences, audience, transport, field_type])
  end

  # Get field from transport config (primary lookup)
  defp get_transport_field(transport, field_type) do
    config = Application.get_env(:ash_dispatch, :recipient_fields, [])
    get_in(config, [transport, field_type])
  end

  # Get generic default field (fallback for backwards compatibility)
  defp get_generic_field(field_type) do
    config = Application.get_env(:ash_dispatch, :recipient_fields, [])
    config[field_type]
  end

  # Extract field value from recipient using various formats

  # Fallback chain - try each field in order until one returns a value
  defp extract_field(recipient, fields) when is_list(fields) do
    Enum.find_value(fields, fn field ->
      extract_field(recipient, field)
    end)
  end

  defp extract_field(recipient, field) when is_atom(field) do
    recipient
    |> Map.get(field)
    |> unwrap_ci_string()
  end

  defp extract_field(recipient, {:field, field}) when is_atom(field) do
    recipient
    |> Map.get(field)
    |> unwrap_ci_string()
  end

  defp extract_field(recipient, {:field, path}) when is_list(path) do
    recipient
    |> get_in(path)
    |> unwrap_ci_string()
  end

  defp extract_field(recipient, {:string_field, key}) when is_binary(key) do
    recipient
    |> Map.get(key)
    |> unwrap_ci_string()
  end

  defp extract_field(recipient, fun) when is_function(fun, 1) do
    recipient
    |> fun.()
    |> unwrap_ci_string()
  end

  defp extract_field(_recipient, nil), do: nil

  defp extract_field(recipient, field_spec) do
    raise """
    Invalid field specification: #{inspect(field_spec)}
    Recipient: #{inspect(recipient)}

    Valid formats:
    - :field_name
    - [:field1, :field2, ...]  (fallback chain)
    - {:field, :field_name}
    - {:field, [:nested, :path]}
    - {:string_field, "key"}
    - &Module.function/1
    """
  end

  # Handle CiString (case-insensitive string) types from Ash
  defp unwrap_ci_string(%{string: value}) when is_binary(value), do: value
  defp unwrap_ci_string(%{data: value}) when is_binary(value), do: value
  defp unwrap_ci_string(value), do: value

  # Error when no config is found
  defp raise_missing_config_error(transport, audience, field_type) do
    raise """
    No #{field_type} field configured for #{transport} transport (#{audience} audience).

    AshDispatch doesn't assume field names - you must configure them.

    Add transport config to config/config.exs:

        config :ash_dispatch,
          recipient_fields: [
            #{transport}: [
              #{field_type}: :your_field_name
            ]
          ]

    Or add audience-specific override:

        config :ash_dispatch,
          recipient_fields: [
            #{transport}: [#{field_type}: :default_field],
            audiences: [
              #{audience}: [
                #{transport}: [#{field_type}: :your_field]
              ]
            ]
          ]

    Or override in event DSL:

        dispatch do
          event :my_event,
            recipient: [
              #{transport}: [#{field_type}: :your_field]
            ]
        end
    """
  end

  # Error when field extraction fails
  defp raise_extraction_error(recipient, field, transport, audience, field_type) do
    # Try to get config sources for debugging
    event_config = nil
    audience_config = get_audience_transport_field(audience, transport, field_type)
    transport_config = get_transport_field(transport, field_type)
    generic_config = get_generic_field(field_type)

    raise """
    Could not extract #{field_type} from recipient for #{transport} transport (#{audience} audience).

    Expected field: #{inspect(field)}
    Recipient type: #{inspect(recipient.__struct__)}
    Available keys: #{inspect(Map.keys(recipient))}

    Configuration resolution:
    1. Event DSL: #{inspect(event_config) || "not set"}
    2. Audience (#{audience}) + Transport (#{transport}): #{inspect(audience_config) || "not set"}
    3. Transport (#{transport}): #{inspect(transport_config) || "not set"}
    4. Generic default: #{inspect(generic_config) || "not set"}
    → Resolved to: #{inspect(field)}

    The recipient must have this field, or you must change the configuration.

    Fix options:
    1. Add field #{inspect(field)} to your recipient struct
    2. Change config to use an existing field
    3. Use custom extraction function
    """
  end
end
