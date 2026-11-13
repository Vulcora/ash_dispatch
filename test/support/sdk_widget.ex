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
