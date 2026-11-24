defmodule AshDispatch.Test.SampleThing do
  @moduledoc false
  use Ash.Resource, domain: nil, validate_domain_inclusion?: false

  attributes do
    uuid_primary_key :id

    attribute :name, :string, public?: true
    attribute :slug, :ci_string, public?: true
    attribute :count, :integer, public?: true
    attribute :ratio, :float, public?: true
    attribute :amount, :decimal, public?: true
    attribute :active, :boolean, public?: true
    attribute :payload, :map, public?: true
    attribute :tags, {:array, :string}, public?: true
    attribute :kind, :atom, public?: true, constraints: [one_of: [:small, :large]]
    attribute :status, :string, public?: true, default: "draft"
    attribute :starts_on, :date, public?: true
    attribute :starts_at, :utc_datetime, public?: true
    attribute :seen_at, :utc_datetime_usec, public?: true
    attribute :secret, :string, public?: false
    attribute :owner_id, :uuid, public?: true, allow_nil?: false
    attribute :reviewer_id, :uuid, public?: true
    attribute :parent_id, :uuid, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :parent, AshDispatch.Test.SampleThing do
      allow_nil? true
      define_attribute? false
    end

    has_many :children, AshDispatch.Test.SampleThing do
      destination_attribute :id
    end
  end

  actions do
    defaults [:read]
  end
end
