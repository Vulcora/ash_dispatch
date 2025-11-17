# AshDispatch

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**Status:** 🚧 **Active Development** - Extracting proven notification engine from Magasin into reusable Ash extension

---

**AshDispatch** is an event-driven notification and messaging system for [Ash Framework](https://ash-hq.org). It provides a declarative DSL for defining events in your resources and automatically dispatching them across multiple transports (email, in-app notifications, Discord, Slack, webhooks, etc.).

## Why AshDispatch?

### Declarative Event Definitions

Define events directly in your resources using familiar Ash DSL patterns:

```elixir
defmodule MyApp.Orders.ProductOrder do
  use Ash.Resource,
    extensions: [AshDispatch.Resource]

  actions do
    create :create_from_cart do
      accept [:user_id]
      # Your action logic...
    end
  end

  dispatch do
    event :created,
      trigger_on: :create_from_cart,
      channels: [
        [transport: :in_app, audience: :user],
        [transport: :email, audience: :user, delay: 300]
      ],
      content: [
        subject: "Order #{{order_number}} created",
        notification_title: "Your order was created",
        notification_message: "Order #{{order_number}} is being processed"
      ],
      metadata: [
        notification_type: :success
      ]
  end
end
```

### Key Features

- **🎯 Automatic Dispatch** - Events are automatically triggered by resource actions
- **📬 Multi-Transport** - Email, in-app, Discord, Slack, SMS, webhooks out of the box
- **⏰ Delayed Delivery** - Schedule notifications for later delivery
- **👤 User Preferences** - Respect user notification preferences automatically
- **📊 Delivery Tracking** - Full audit trail with delivery receipts
- **🔄 Automatic Retries** - Failed deliveries retry with exponential backoff
- **🎨 Template Interpolation** - `{{variable}}` syntax for dynamic content
- **🔌 Extensible** - Add custom transports and event modules
- **🧪 Test-Friendly** - Factory integration for testing templates

## Tutorials

- [Getting Started with AshDispatch](documentation/tutorials/getting-started.md)
- [Migrating from Manual Event Handling](documentation/tutorials/migrating-from-manual.md)

## Topics

- [What is AshDispatch?](documentation/topics/what-is-ash-dispatch.md)
- [Understanding Events](documentation/topics/events.md)
- [Delivery Transports](documentation/topics/transports.md)
- [User Preferences](documentation/topics/user-preferences.md)
- [Template Interpolation](documentation/topics/template-interpolation.md)
- [Delivery Receipts & Tracking](documentation/topics/delivery-tracking.md)
- [Counter Broadcasting](documentation/topics/counter-broadcasting.md)
- [Testing Events](documentation/topics/testing-events.md)

## Reference

- [AshDispatch.Resource DSL](documentation/dsls/DSL-AshDispatch-Resource.md)
- [AshDispatch.Domain DSL](documentation/dsls/DSL-AshDispatch-Domain.md) _(coming soon)_

## Architecture Overview

```mermaid
graph TB
    A[Resource Action] -->|triggers| B[Event]
    B -->|creates| C[DeliveryReceipt]
    C -->|dispatches to| D{Transport}
    D -->|in_app| E[Notification]
    D -->|email| F[Oban Job]
    D -->|discord| G[Webhook]
    F -->|sends| H[Email Service]
    E -->|updates| I[User UI]
    G -->|posts| J[Discord Channel]
```

## Installation

```elixir
def deps do
  [
    {:ash_dispatch, "~> 0.1.0"}
  ]
end
```

## Quick Example

```elixir
# 1. Add extension to resource
defmodule MyApp.Tickets.Ticket do
  use Ash.Resource,
    extensions: [AshDispatch.Resource]

  # 2. Define events
  dispatch do
    # Simple inline event
    event :created,
      trigger_on: :create,
      channels: [
        [transport: :in_app, audience: :user],
        [transport: :email, audience: :admin]
      ],
      content: [
        subject: "New ticket: {{title}}",
        notification_title: "Ticket Created",
        notification_message: "{{user_name}} created a new ticket"
      ]

    # Complex event with callback module
    event :status_changed,
      trigger_on: [:resolve, :close, :reopen],
      module: MyApp.Events.Tickets.StatusChanged
  end
end

# 3. That's it! Events dispatch automatically when actions run
Ticket
|> Ash.Changeset.for_create(:create, %{title: "Bug report"})
|> Ash.create!()
# -> Automatically dispatches :created event
# -> Creates in-app notification for user
# -> Sends email to admin
```

## Design Principles

### 1. Resource-Centric
Events are defined in resources, just like actions, attributes, and relationships.

### 2. Progressive Complexity
Start with simple inline events. Upgrade to callback modules when you need custom logic.

### 3. Receipt-First Pattern
All deliveries create a receipt record before dispatch, enabling full audit trails and reliable retries.

### 4. Fail-Safe Defaults
User preferences, rate limiting, and delivery policies protect users from notification fatigue.

### 5. Framework Integration
Deep integration with Ash actions, Oban jobs, and the Ash ecosystem.

## Development Status

**Current:** ✅ Resource extension complete and tested
**Next:** 🚧 Runtime dispatcher and Domain extension

See [DISPATCH_WORKFLOW.md](../../../DISPATCH_WORKFLOW.md) for detailed development notes and decisions.

## Contributing

This is currently being extracted from [Magasin](https://github.com/fyndgrossisten/magasin) where it has been running in production. Once stabilized, it will be published as a standalone package.

## License

MIT License - see LICENSE file for details.

## Acknowledgments

Built on the excellent [Ash Framework](https://ash-hq.org) by Zach Daniel and the Ash community.

Inspired by patterns from AshStateMachine, AshAuthentication, and years of building notification systems.
