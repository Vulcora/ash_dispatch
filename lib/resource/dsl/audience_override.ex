defmodule AshDispatch.Resource.Dsl.AudienceOverride do
  @moduledoc """
  DSL entity struct for explicit audience path overrides.

  Allows defining custom relationship paths for specific audiences,
  useful when an audience needs a different path than the default
  or when combined with audience_prefix.
  """

  defstruct [
    :name,
    :path,
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{
          name: atom(),
          path: [atom()],
          __spark_metadata__: any()
        }
end
