defmodule AshDispatch.Test.StrictReceipt do
  @moduledoc """
  ETS-backed receipt that refuses the same state transitions as
  `AshDispatch.Resources.DeliveryReceipt.Base`.

  `AshDispatch.Test.TransportReceipt` lets any action run from any state, which
  is enough for most tests and wrong for one kind: a test about what the worker
  does when the state machine says no. `test/workers/send_email_interrupted_test.exs`
  compares this resource's transitions with the real one's, so the two cannot
  drift apart unnoticed.
  """
  use Ash.Resource,
    domain: AshDispatch.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshStateMachine]

  ets do
    private? true
  end

  state_machine do
    initial_states([:pending, :scheduled, :sending, :sent, :failed, :failed_permanent, :skipped])
    default_initial_state(:pending)
    state_attribute(:status)

    transitions do
      transition(:mark_sending, from: [:scheduled, :pending, :failed, :batched], to: :sending)
      transition(:resume_sending, from: :sending, to: :sending)
      transition(:mark_sent, from: [:sending, :scheduled, :pending, :failed], to: :sent)
      transition(:mark_failed, from: [:sending, :scheduled, :pending], to: :failed)

      transition(:mark_failed_permanent,
        from: [:sending, :scheduled, :failed],
        to: :failed_permanent
      )

      transition(:skip, from: [:pending, :scheduled, :sending, :batched], to: :skipped)
    end
  end

  attributes do
    uuid_primary_key :id

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
    attribute :provider_id, :string, public?: true
    attribute :provider_response, :map, public?: true
    attribute :source_type, :string, public?: true
    attribute :source_id, :string, public?: true
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
        :content,
        :source_type,
        :source_id
      ]
    end

    update :mark_sending do
      change transition_state(:sending)
    end

    update :resume_sending do
      require_atomic? false
      change transition_state(:sending)

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :updated_at,
          AshDispatch.Clock.utc_now()
        )
      end
    end

    update :mark_sent do
      accept [:notification_id, :provider_id, :provider_response]
      change transition_state(:sent)
    end

    update :mark_failed do
      require_atomic? false
      accept [:error_message]
      change transition_state(:failed)
      change {AshDispatch.Changes.PutReasonCode, []}
    end

    update :mark_failed_permanent do
      require_atomic? false
      accept [:error_message]
      change transition_state(:failed_permanent)
      change {AshDispatch.Changes.PutReasonCode, []}
    end

    update :skip do
      require_atomic? false
      accept [:error_message]
      change transition_state(:skipped)
      change {AshDispatch.Changes.PutReasonCode, []}
    end
  end
end

defmodule AshDispatch.Test.NarrowedReceipt do
  @moduledoc """
  A host that narrowed `:resume_sending` so `:sending` is not a source for it.

  One of the two causes `AshDispatch.ReceiptStatus.claim/2` may answer
  `{:ok, receipt}` to: the receipt is already `:sending` and this attempt owns
  it, so the letter is sent from the receipt as it stands.
  """
  use Ash.Resource,
    domain: AshDispatch.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshStateMachine]

  ets do
    private? true
  end

  state_machine do
    initial_states([:pending, :scheduled, :sending])
    default_initial_state(:pending)
    state_attribute(:status)

    transitions do
      transition(:mark_sending, from: [:scheduled, :pending], to: :sending)
      # Declared, and narrowed: no source at all.
      transition(:resume_sending, from: :scheduled, to: :sending)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :event_id, :string, public?: true
    attribute :transport, :atom, default: :email, public?: true
    attribute :recipient, :string, public?: true
    attribute :subject, :string, public?: true
    attribute :body_text, :string, public?: true
    attribute :content, :map, default: %{}, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:read]

    create :create do
      accept [:status, :event_id, :transport, :recipient, :subject, :body_text, :content]
    end

    update :mark_sending do
      change transition_state(:sending)
    end

    update :resume_sending do
      change transition_state(:sending)
    end
  end
end

defmodule AshDispatch.Test.RefusingReceipt do
  @moduledoc """
  A receipt resource whose `:resume_sending` fails for a reason that is NOT a
  refused transition — a validation of the host's own.

  `claim/2` must propagate that: answering `{:ok, receipt}` would send the
  letter with the receipt left behind saying something else.
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
    attribute :transport, :atom, default: :email, public?: true
    attribute :recipient, :string, public?: true
    attribute :content, :map, default: %{}, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:read]

    create :create do
      accept [:status, :event_id, :transport, :recipient, :content]
    end

    update :resume_sending do
      require_atomic? false

      validate fn _changeset, _context ->
        {:error, field: :base, message: "this host refuses to resume"}
      end
    end
  end
end
