defmodule AshDispatch.Test.Ticket do
  @moduledoc """
  Test resource with inline events (no explicit module).
  Used to test automatic module derivation and generation.
  """
  use Ash.Resource,
    domain: AshDispatch.Test.Domain,
    extensions: [AshDispatch.Resource]

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :status, :atom, default: :open, public?: true
  end

  actions do
    defaults [:read]

    create :create do
      accept [:title]
    end

    update :assign do
      accept []
    end

    update :close do
      accept []
    end
  end

  dispatch do
    # Inline event - should generate module
    event :created,
      trigger_on: :create,
      channels: [
        [transport: :in_app, audience: :user]
      ],
      content: [
        notification_title: "Ticket Created",
        notification_message: "Ticket {{title}} was created"
      ]

    # Inline event with email - should generate module with templates
    event :assigned,
      trigger_on: :assign,
      channels: [
        [transport: :in_app, audience: :user],
        [transport: :email, audience: :user]
      ],
      content: [
        subject: "Ticket assigned to you",
        notification_title: "Ticket Assigned"
      ]
  end
end
