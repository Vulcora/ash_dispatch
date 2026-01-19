# Localization (i18n)

AshDispatch provides built-in internationalization (i18n) support for sending notifications in the recipient's preferred language. This guide covers how to configure locale-aware templates and dynamic locale resolution.

## Overview

The localization system supports:

- **Resource-level locale configuration** - Set default locales for all events in a resource
- **Event-level locale override** - Customize locales per event
- **Channel-level locale override** - Set static or dynamic locale per channel
- **Template fallback chain** - Graceful degradation when locale-specific templates don't exist
- **Delivery receipt tracking** - Track which locale was used for each delivery

## Quick Start

### 1. Configure Locales in Resource DSL

```elixir
defmodule MyApp.Leads.Lead do
  use Ash.Resource,
    extensions: [AshDispatch.Resource]

  dispatch do
    # Resource-level: applies to ALL events
    locales ["sv", "en"], locale_from: :visitor_locale

    event :created, trigger_on: :create do
      channels [
        # Customer email uses visitor_locale from record
        [transport: :email, audience: :customer],
        # Admin email always in Swedish
        [transport: :email, audience: :admin, locale: "sv"]
      ]
    end
  end

  attributes do
    # The field used for locale resolution
    attribute :visitor_locale, :string do
      constraints max_length: 10
    end
  end
end
```

### 2. Generate Templates

Run the code generator to create locale-specific templates:

```bash
mix ash.codegen create_lead_templates
```

This generates:
```
priv/ash_dispatch/leads/events/created/templates/
├── email.html.heex        # Default fallback
├── email.sv.html.heex     # Swedish
├── email.en.html.heex     # English
├── email.text.eex         # Default fallback (text)
├── email.sv.text.eex      # Swedish (text)
└── email.en.text.eex      # English (text)
```

### 3. Write Locale-Specific Templates

```heex
<%# email.sv.html.heex - Swedish %>
<h1>Hej <%= @contact_name %>!</h1>
<p>Tack för att du kontaktade oss. Vi återkommer snart.</p>
```

```heex
<%# email.en.html.heex - English %>
<h1>Hello <%= @contact_name %>!</h1>
<p>Thank you for contacting us. We'll get back to you soon.</p>
```

## Configuration Options

### Resource-Level Configuration

Configure locales for all events in a resource:

```elixir
dispatch do
  locales ["sv", "en", "no"],
    default_locale: "sv",
    locale_from: :visitor_locale
end
```

| Option | Description |
|--------|-------------|
| `locales` | List of locale codes to generate templates for |
| `default_locale` | Fallback when locale can't be determined |
| `locale_from` | Field on record to read runtime locale from |

### Event-Level Configuration

Override resource settings for a specific event:

```elixir
event :created,
  trigger_on: :create,
  locales: ["sv", "en", "de"],  # Override resource locales
  locale_from: :preferred_language  # Different field
```

### Channel-Level Configuration

Override per channel for fine-grained control:

```elixir
channels [
  # Static locale (always use Swedish)
  [transport: :email, audience: :admin, locale: "sv"],

  # Dynamic locale from record field
  [transport: :email, audience: :customer, locale_from: :visitor_locale],

  # Generate templates for specific locales
  [transport: :email, audience: :customer, locales: ["sv", "en"]]
]
```

## Locale Resolution Priority

At runtime, locale is resolved in this order (highest to lowest):

1. **Channel-level `locale`** - Static locale on channel (e.g., `locale: "sv"`)
2. **Channel-level `locale_from`** - Dynamic from record field
3. **Event-level `locale_from`** - Field configured on event
4. **Resource-level `locale_from`** - Field configured on resource
5. **Common field names** - Auto-detected: `visitor_locale`, `locale`
6. **Config default** - `config :ash_dispatch, default_locale: "sv"`

## Template Fallback Chain

When resolving templates, AshDispatch tries these in order:

1. `email.admin.sv.html.heex` (variant + locale)
2. `email.admin.html.heex` (variant only)
3. `email.sv.html.heex` (locale only)
4. `email.html.heex` (base template)
5. `default.sv.html.heex` (default + locale)
6. `default.html.heex` (ultimate fallback)

This ensures graceful degradation - you only need to create locale-specific templates for languages where the content differs.

## Global Configuration

Set global defaults in your config:

```elixir
# config/config.exs
config :ash_dispatch,
  default_locale: "sv"  # Default when no locale found (defaults to "en")
```

## Delivery Receipt Tracking

When an event is dispatched, the locale used is recorded in the delivery receipt:

```elixir
# Query receipts by locale
receipts = Ash.read!(MyApp.Deliveries.DeliveryReceipt,
  filter: [locale: "sv"]
)
```

This is useful for:
- Debugging template issues
- Analytics on language distribution
- Compliance reporting

## Common Patterns

### Multi-Language Landing Page

For leads from a multi-language landing page:

```elixir
defmodule MyApp.Leads.Lead do
  dispatch do
    # Locales match your landing page languages
    locales ["sv", "en", "no", "fi"]
    locale_from: :visitor_locale

    event :created, trigger_on: :create do
      channels [
        # Customer gets email in their language
        [transport: :email, audience: :customer],
        # Internal team always in Swedish
        [transport: :email, audience: :admin, locale: "sv"],
        [transport: :in_app, audience: :owner]
      ]
    end
  end
end
```

### Internal-Only Events

For events that only go to internal users:

```elixir
event :escalated,
  trigger_on: :escalate,
  locales: ["sv"],  # Only Swedish templates
  channels: [
    [transport: :email, audience: :admin],
    [transport: :in_app, audience: :owner]
  ]
```

### Customer Portal with User Preferences

For events where users have saved language preferences:

```elixir
event :invoice_sent,
  trigger_on: :send_invoice,
  locale_from: :customer_preferred_language,
  channels: [
    [transport: :email, audience: :customer]
  ]
```

## Testing Locale Templates

Test templates render correctly for each locale:

```elixir
defmodule MyApp.LeadTemplateTest do
  use ExUnit.Case

  test "created event renders in Swedish" do
    lead = %{id: "123", contact_name: "Erik", visitor_locale: "sv"}

    {:ok, html} = AshDispatch.TemplateResolver.render(
      template_path: "priv/ash_dispatch/leads/events/created/templates",
      format: :html,
      transport: :email,
      locale: "sv",
      assigns: %{contact_name: lead.contact_name}
    )

    assert html =~ "Tack för att du kontaktade oss"
  end

  test "created event renders in English" do
    lead = %{id: "123", contact_name: "Erik", visitor_locale: "en"}

    {:ok, html} = AshDispatch.TemplateResolver.render(
      template_path: "priv/ash_dispatch/leads/events/created/templates",
      format: :html,
      transport: :email,
      locale: "en",
      assigns: %{contact_name: lead.contact_name}
    )

    assert html =~ "Thank you for contacting us"
  end

  test "falls back to default when locale template missing" do
    {:ok, html} = AshDispatch.TemplateResolver.render(
      template_path: "priv/ash_dispatch/leads/events/created/templates",
      format: :html,
      transport: :email,
      locale: "de",  # No German template
      assigns: %{contact_name: "Hans"}
    )

    # Should fall back to base template
    assert {:ok, _} = html
  end
end
```

## Migration Guide

### From Hardcoded Templates

If you have existing templates without locale support:

1. Add `locales` configuration to your resource
2. Run `mix ash.codegen` to generate locale-specific templates
3. Copy content from existing templates to locale-specific versions
4. Translate content as needed

### Adding New Locale

To add support for a new language:

1. Add the locale code to your `locales` list
2. Run `mix ash.codegen` to generate new template files
3. Translate the new template files

```elixir
# Before
locales ["sv", "en"]

# After (adding Norwegian)
locales ["sv", "en", "no"]
```

Then run:
```bash
mix ash.codegen add_norwegian_templates
```

## Next Steps

- [Configuration](configuration.md) - All configuration options
- [Code Generation](code-generation.md) - Template generation details
- [Phoenix Integration](phoenix-integration.md) - Real-time updates
