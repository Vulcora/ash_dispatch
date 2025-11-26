# Formatter Configuration Guide

AshDispatch exports formatter configuration to make your DSL code cleaner and more readable.

## Usage in Your Project

Add `:ash_dispatch` to your `.formatter.exs`:

```elixir
[
  import_deps: [:ash, :ash_dispatch],
  inputs: ["*.{ex,exs}", "{config,lib,test}/**/*.{ex,exs}"]
]
```

## Before and After

### Before (without formatter config)

```elixir
dispatch do
  event(:created, [
    trigger_on: :create,
    channels: [
      [transport: :email, audience: :user],
      [transport: :in_app, audience: :admin]
    ],
    content: [
      subject: "Order #{{order_number}} created",
      notification_title: "New order"
    ]
  ])
end
```

### After (with formatter config)

```elixir
dispatch do
  event :created,
    trigger_on: :create,
    channels: [
      [transport: :email, audience: :user],
      [transport: :in_app, audience: :admin]
    ],
    content: [
      subject: "Order #{{order_number}} created",
      notification_title: "New order"
    ]
end
```

## What Gets Formatted

The formatter configuration removes forced parentheses for:

### Main DSL Entities
- `event` - Define dispatch events
- `counter` - Define counter broadcasts

### Event Options
- `trigger_on` - Actions that trigger the event
- `module` - Callback module
- `channels` - Delivery channels
- `content` - Content configuration
- `metadata` - Event metadata
- And many more...

### Channel Options (inline)
- `transport` - Transport type (:email, :in_app, etc.)
- `audience` - Target audience
- `delay` - Delivery delay
- `variant` - Template variant

### Content Options (inline)
- `subject` - Email subject
- `notification_title` - Notification title
- `notification_message` - Notification message
- `action_url` - Action URL

## Running the Formatter

```bash
# Check formatting
mix format --check-formatted

# Apply formatting
mix format
```

## IDE Integration

Most Elixir IDEs (VS Code, IntelliJ, Emacs) respect `.formatter.exs` automatically.
After adding `:ash_dispatch` to `import_deps`, your IDE will format code correctly on save.
