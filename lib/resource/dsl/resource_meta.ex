defmodule AshDispatch.Resource.Dsl.ResourceMeta do
  @moduledoc """
  Data structure for resource_meta configuration in the dispatch section.

  Provides metadata about the resource for TypeScript generation:
  labels, pluralization, navigation paths, and state machine states.

  ## Fields

  - `:label` - Human-readable singular label (e.g., "Task"). Auto-derived from resource name.
  - `:plural` - Plural form (e.g., "tasks"). Auto-derived from postgres table name.
  - `:nav_path` - Navigation base path (e.g., "/tasks"). Auto-derived from plural.
  """

  defstruct [
    :label,
    :plural,
    :nav_path,
    :color_theme,
    :icon,
    :discovery_mode,
    :feature_key,
    :order,
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{
          label: String.t() | nil,
          plural: String.t() | nil,
          nav_path: String.t() | nil,
          color_theme: String.t() | nil,
          icon: String.t() | nil,
          discovery_mode: String.t() | nil,
          feature_key: String.t() | nil,
          order: number() | nil
        }
end
