defmodule AshDispatch.Resource.Dsl.AudiencePrefix do
  @moduledoc """
  DSL entity struct for audience prefix configuration.

  Specifies a relationship prefix that all relationship-based audiences
  should go through before resolving. Used by child resources that access
  users through parent relationships.
  """

  defstruct [
    :prefix,
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{
          prefix: atom(),
          __spark_metadata__: any()
        }
end
