defmodule AshDispatch.Test.TransportReceipt do
  @moduledoc """
  ETS-backed stand-in for `AshDispatch.Resources.DeliveryReceipt.Base`,
  carrying just the fields and lifecycle actions the transports touch in
  `deliver/4`.

  The library test suite has no Repo, so the real (AshPostgres) receipt
  resource can't be exercised here — but the transports only need a
  resource that answers `Ash.get/3` and accepts `:skip` / `:schedule` /
  `:mark_failed`, which ETS does.
  """
  use Ash.Resource,
    domain: AshDispatch.Test.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id

    attribute :status, :atom, default: :pending, public?: true
    attribute :event_id, :string, public?: true
    attribute :audience, :atom, public?: true
    attribute :transport, :atom, default: :email, public?: true
    attribute :user_id, :uuid, public?: true
    attribute :recipient, :string, public?: true
    attribute :subject, :string, public?: true
    attribute :body_html, :string, public?: true
    attribute :body_text, :string, public?: true
    attribute :content, :map, default: %{}, public?: true
    attribute :error_message, :string, public?: true
    attribute :oban_job_id, :integer, public?: true
    attribute :notification_id, :uuid, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [
        :status,
        :event_id,
        :audience,
        :transport,
        :user_id,
        :recipient,
        :subject,
        :body_html,
        :body_text,
        :content
      ]
    end

    update :skip do
      accept [:error_message]
      change set_attribute(:status, :skipped)
    end

    update :schedule do
      accept [:oban_job_id]
      change set_attribute(:status, :scheduled)
    end

    update :mark_sent do
      accept [:notification_id]
      change set_attribute(:status, :sent)
    end

    update :mark_failed do
      accept [:error_message]
      change set_attribute(:status, :failed)
    end
  end
end
