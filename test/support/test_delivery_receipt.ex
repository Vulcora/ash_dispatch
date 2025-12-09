defmodule AshDispatch.Test.DeliveryReceipt do
  @moduledoc """
  Test delivery receipt resource using ETS for webhook handler tests.
  """
  use Ash.Resource,
    domain: AshDispatch.Test.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id

    attribute :provider_id, :string, allow_nil?: true, public?: true
    attribute :status, :atom, default: :pending, public?: true
    attribute :event_id, :string, allow_nil?: true, public?: true
    attribute :recipient, :string, allow_nil?: true, public?: true
    attribute :transport, :atom, default: :email, public?: true
    attribute :provider_response, :map, default: %{}, public?: true

    # Webhook timestamp fields
    attribute :sent_at, :utc_datetime, public?: true
    attribute :delivered_at, :utc_datetime, public?: true
    attribute :opened_at, :utc_datetime, public?: true
    attribute :clicked_at, :utc_datetime, public?: true
    attribute :bounced_at, :utc_datetime, public?: true
    attribute :complained_at, :utc_datetime, public?: true
    attribute :failed_at, :utc_datetime, public?: true
    attribute :delivery_delayed_at, :utc_datetime, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:provider_id, :status, :event_id, :recipient, :transport]
    end

    read :get_by_provider_id do
      argument :provider_id, :string, allow_nil?: false
      get? true
      filter expr(provider_id == ^arg(:provider_id))
    end

    update :record_webhook_event do
      accept [
        :provider_response,
        :sent_at,
        :delivered_at,
        :opened_at,
        :clicked_at,
        :bounced_at,
        :complained_at,
        :failed_at,
        :delivery_delayed_at
      ]
    end
  end
end
