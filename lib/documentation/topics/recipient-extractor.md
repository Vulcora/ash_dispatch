# Recipient Field Extraction

AshDispatch uses a **transport-first configuration** approach for extracting recipient information. Each transport (email, SMS, Discord, in-app) can have different identifier and display name fields, with optional per-audience overrides.

> **API Documentation**: For complete function documentation, see `AshDispatch.Event.RecipientExtractor`.

## Why Transport-First?

Different transports need different recipient data:
- **Email** needs an email address
- **SMS** needs a phone number
- **Discord** needs a Discord ID
- **In-app** needs a user ID

Rather than forcing a generic "identifier" that doesn't fit all cases, you configure each transport's needs explicitly.

## Quick Start

### Minimal Configuration

Configure the transports you use:

```elixir
# config/config.exs
config :ash_dispatch,
  recipient_fields: [
    email: [
      identifier: :email,
      name: :contact_person
    ],
    in_app: [
      identifier: :id,
      name: :contact_person
    ]
  ]
```

That's it! AshDispatch now knows how to extract recipient info for email and in-app notifications.

### Adding More Transports

Add other transports as you need them:

```elixir
config :ash_dispatch,
  recipient_fields: [
    email: [
      identifier: :email,
      name: [:display_name, :name, :contact_person]  # fallback chain
    ],
    sms: [
      identifier: :mobile_phone,
      name: [:first_name, :name]
    ],
    discord: [
      identifier: :discord_id,
      name: [:app_username, :display_name, :name]
    ],
    in_app: [
      identifier: :id,
      name: [:display_name, :name]
    ]
  ]
```

## Fallback Chains

For the `name` field, you can specify a list of fields to try in order:

```elixir
name: [:display_name, :name, :contact_person, :full_name]
```

The extractor tries each field until one returns a value. This is useful when your User model might have different name fields populated.

## Per-Audience Overrides

Different audience types might have different field names. Configure overrides per audience:

```elixir
config :ash_dispatch,
  recipient_fields: [
    # Default transport configuration
    email: [
      identifier: :email,
      name: [:display_name, :name]
    ],

    # Audience-specific overrides
    audiences: [
      # Admins show full name in emails
      admin: [
        email: [name: :full_name]
      ],

      # Customers use company info
      customer: [
        email: [
          identifier: :contact_email,
          name: [:company_name, :contact_person]
        ]
      ]
    ]
  ]
```

When sending to `:admin` audience via `:email` transport:
1. Uses `:email` for identifier (from transport default)
2. Uses `:full_name` for name (from audience override)

## Resolution Order

The system resolves fields in this order (most specific first):

1. **Event DSL override** - Configured directly in the event definition
2. **Audience + Transport** - `audiences: [admin: [email: [name: :full_name]]]`
3. **Transport default** - `email: [identifier: :email]`
4. **Error** - Clear error message with guidance

## Event-Level Overrides

Override fields for specific events using the DSL:

```elixir
# In your resource
dispatch do
  event :special_case,
    trigger_on: :special_action,
    recipient: [
      email: [
        identifier: :backup_email,
        name: :preferred_name
      ]
    ]
end
```

Or in standalone event modules:

```elixir
defmodule MyApp.Events.SpecialEvent do
  use AshDispatch.Event

  dispatch do
    id "special.event"

    recipient do
      email do
        identifier :alternate_email
        name :display_name
      end
    end

    channels do
      channel :email, :user
    end
  end
end
```

## Advanced Field Formats

### Simple Atom (Most Common)

```elixir
identifier: :email
name: :contact_person
```

### Fallback Chain (List of Atoms)

```elixir
name: [:display_name, :name, :contact_person, :full_name]
```

Tries each field in order until one returns a value.

### Nested Fields

For data stored in nested structures:

```elixir
identifier: {:field, [:contact, :email]}
name: {:field, [:profile, :display_name]}
```

Works with structs like:
```elixir
%User{
  contact: %{email: "user@example.com"},
  profile: %{display_name: "John"}
}
```

### String Keys (JSON Data)

For maps with string keys:

```elixir
identifier: {:string_field, "email_address"}
```

### Custom Functions

For complex extraction logic:

```elixir
identifier: &MyApp.extract_primary_contact/1
name: &MyApp.format_recipient_name/1
```

```elixir
defmodule MyApp do
  def extract_primary_contact(recipient) do
    recipient.emails
    |> Enum.find(&(&1.primary == true))
    |> Map.get(:address)
  end

  def format_recipient_name(recipient) do
    "#{recipient.first_name} #{recipient.last_name}"
  end
end
```

## CiString Support

AshDispatch automatically unwraps `Ash.CiString` (case-insensitive string) values. If your email field uses `Ash.Type.CiString`, it will be extracted correctly without any additional configuration.

## Clear Error Messages

If configuration is missing, you get helpful guidance:

```
No identifier field configured for email transport (user audience).

AshDispatch doesn't assume field names - you must configure them.

Add transport config to config/config.exs:

    config :ash_dispatch,
      recipient_fields: [
        email: [
          identifier: :your_field_name
        ]
      ]

Or add audience-specific override:

    config :ash_dispatch,
      recipient_fields: [
        email: [identifier: :default_field],
        audiences: [
          user: [
            email: [identifier: :your_field]
          ]
        ]
      ]
```

If a field is missing from the recipient:

```
Could not extract identifier from recipient for email transport (user audience).

Expected field: :email
Recipient type: MyApp.Accounts.Lead
Available keys: [:id, :primary_email, :company_name]

Fix options:
1. Add field :email to your recipient struct
2. Change config to use an existing field (:primary_email)
3. Use custom extraction function
```

## Real-World Examples

### E-commerce Platform

```elixir
config :ash_dispatch,
  recipient_fields: [
    email: [
      identifier: :email,
      name: [:full_name, :name]
    ],
    sms: [
      identifier: :phone_number,
      name: :first_name
    ],
    in_app: [
      identifier: :id,
      name: [:full_name, :name]
    ]
  ]
```

### B2B Platform

```elixir
config :ash_dispatch,
  recipient_fields: [
    email: [
      identifier: :email,
      name: [:contact_person, :company_name]
    ],
    in_app: [
      identifier: :id,
      name: [:contact_person, :company_name]
    ],

    audiences: [
      # Leads use different fields
      lead: [
        email: [
          identifier: :primary_email,
          name: :company_name
        ]
      ],

      # Partners have nested contact info
      partner: [
        email: [
          identifier: {:field, [:primary_contact, :email]},
          name: {:field, [:primary_contact, :name]}
        ]
      ]
    ]
  ]
```

### Multi-Channel Platform with Discord

```elixir
config :ash_dispatch,
  recipient_fields: [
    email: [
      identifier: :email,
      name: [:display_name, :name]
    ],
    discord: [
      identifier: :discord_id,
      name: [:discord_username, :display_name, :name]
    ],
    slack: [
      identifier: :slack_id,
      name: [:slack_display_name, :name]
    ],
    in_app: [
      identifier: :id,
      name: [:display_name, :name]
    ]
  ]
```

## Testing

The RecipientExtractor is fully testable:

```elixir
test "extracts identifier from custom struct" do
  recipient = %{
    id: "123",
    primary_email: "test@example.com",
    full_name: "Test User"
  }

  # With custom config
  event_config = %{
    recipient: %{
      email: %{
        identifier: :primary_email,
        name: :full_name
      }
    }
  }

  identifier = RecipientExtractor.extract_identifier(
    recipient,
    :email,
    :user,
    event_config[:recipient]
  )

  assert identifier == "test@example.com"
end
```

## See Also

- [Configuration Guide](configuration.html) - Complete configuration reference
- [Recipient Resolution](recipient-resolution.html) - How audiences resolve to recipients
- `AshDispatch.Event.RecipientExtractor` - Module documentation
