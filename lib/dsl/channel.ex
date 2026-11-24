defmodule AshDispatch.Dsl.Channel do
  @moduledoc """
  DSL entity struct for channel definitions.

  This is used by Spark to store channel configurations from the DSL.
  At runtime, these are converted to `AshDispatch.Channel` structs.
  """

  defstruct [
    :transport,
    :audience,
    :variant,
    :locale,
    :locale_from,
    :layout,
    :layout_from,
    :queue,
    :webhook_url,
    :deduplicate_group,
    :idempotency_source,
    __spark_metadata__: nil,
    time: {:in, 0},
    policy: :always,
    optional: false,
    exclude_actor: false,
    content: %{},
    metadata: %{},
    opts: %{},
    counters: [],
    load: [],
    locales: []
  ]

  @type t :: %__MODULE__{
          transport: atom(),
          audience: atom(),
          time: any(),
          policy: atom(),
          variant: atom() | nil,
          locale: String.t() | nil,
          locale_from: atom() | nil,
          locales: [String.t()],
          layout: atom() | String.t() | nil,
          layout_from: atom() | nil,
          queue: atom() | nil,
          webhook_url: String.t() | nil,
          deduplicate_group: atom() | nil,
          idempotency_source: atom() | nil,
          optional: boolean(),
          exclude_actor: boolean(),
          content: map(),
          metadata: map(),
          opts: map(),
          counters: [atom()],
          load: [atom() | {atom(), any()}]
        }
end
