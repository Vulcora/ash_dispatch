defmodule AshDispatch.Test.SdkDomain do
  @moduledoc false
  # A domain of its own, configured by `test/mix/tasks/ash_dispatch_gen_sdk_test.exs`
  # and by nothing else: `config :ash_dispatch, :domains` is global, so a test
  # that points the code generator at a domain must not point it at the one the
  # rest of the suite dispatches through.
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshDispatch.Test.SdkWidget
  end
end

defmodule AshDispatch.Test.SdkWidget do
  @moduledoc false
  # A resource the generated SDK has something to say about (`resource_meta`)
  # and no events at all — so `sdk: :if_events` sees content while nothing in
  # the suite's own tree needs a template or an event module written for it.
  use Ash.Resource,
    domain: AshDispatch.Test.SdkDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshDispatch.Resource]

  dispatch do
    resource_meta(label: "Widget", plural: "widgets", nav_path: "/widgets")
  end

  attributes do
    uuid_primary_key :id
  end

  actions do
    defaults [:read]
  end
end

# ============================================================================
# `sdk: :if_events`: the host's own content, and the bases' (#50)
# ============================================================================

defmodule AshDispatch.Test.SdkBases.Domain do
  @moduledoc false
  # A host with an in-app inbox and NOTHING of its own: the three `Base`
  # macros and no event, counter, `resource_meta` or `entity_changes` anywhere.
  # `Notification.Base` still brings `unread_notifications`, which is the whole
  # of the report: in 0.9.4-rc.2 that counted, and `sdk: :if_events` therefore
  # generated the client for every host with an inbox.
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshDispatch.Test.SdkBases.Notification
    resource AshDispatch.Test.SdkBases.Preference
    resource AshDispatch.Test.SdkBases.Receipt
  end
end

defmodule AshDispatch.Test.SdkBases.Notification do
  @moduledoc false
  # ETS: nothing here is ever run, and the generator reads the DSL, not rows.
  use AshDispatch.Resources.Notification.Base,
    repo: AshDispatch.Test.Setup.Repo,
    domain: AshDispatch.Test.SdkBases.Domain,
    data_layer: Ash.DataLayer.Ets
end

defmodule AshDispatch.Test.SdkBases.Preference do
  @moduledoc false
  use AshDispatch.Resources.Preference.Base,
    repo: AshDispatch.Test.Setup.Repo,
    domain: AshDispatch.Test.SdkBases.Domain,
    data_layer: Ash.DataLayer.Ets
end

defmodule AshDispatch.Test.SdkBases.Receipt do
  @moduledoc false
  use AshDispatch.Resources.DeliveryReceipt.Base,
    repo: AshDispatch.Test.Setup.Repo,
    domain: AshDispatch.Test.SdkBases.Domain,
    notification_resource: AshDispatch.Test.SdkBases.Notification,
    data_layer: Ash.DataLayer.Ets
end

defmodule AshDispatch.Test.SdkOwnCounter.Domain do
  @moduledoc false
  # The same host, plus one counter it declared itself.
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshDispatch.Test.SdkBases.Notification
    resource AshDispatch.Test.SdkOwnCounter.Ticket
  end
end

defmodule AshDispatch.Test.SdkOwnCounter.Ticket do
  @moduledoc false
  use Ash.Resource,
    domain: AshDispatch.Test.SdkOwnCounter.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshDispatch.Resource]

  counters do
    counter :open_tickets, trigger_on: [:create], audience: :user
  end

  attributes do
    uuid_primary_key :id
  end

  actions do
    defaults [:read, :create]
  end
end

defmodule AshDispatch.Test.SdkOneEvent.Domain do
  @moduledoc false
  # The same host, plus one event it declared itself. In-app only and with an
  # explicit `module:`, so the generator wants no template and no event module
  # written into this repository — only the SDK, which is what is under test.
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshDispatch.Test.SdkBases.Notification
    resource AshDispatch.Test.SdkOneEvent.Ticket
  end
end

defmodule AshDispatch.Test.SdkOneEvent.Event do
  @moduledoc false
  use AshDispatch.Event

  @impl true
  def event_id, do: "sdk_tickets.opened"
end

defmodule AshDispatch.Test.SdkOneEvent.Ticket do
  @moduledoc false
  use Ash.Resource,
    domain: AshDispatch.Test.SdkOneEvent.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshDispatch.Resource]

  dispatch do
    event :opened,
      trigger_on: :create,
      module: AshDispatch.Test.SdkOneEvent.Event,
      channels: [[transport: :in_app, audience: :user]],
      content: [
        notification_title: "Opened",
        notification_message: "A ticket was opened"
      ]
  end

  attributes do
    uuid_primary_key :id
  end

  actions do
    defaults [:read, :create]
  end
end
