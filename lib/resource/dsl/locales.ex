defmodule AshDispatch.Resource.Dsl.Locales do
  @moduledoc """
  DSL entity struct for resource-level locale configuration.

  Defines which locales should have templates generated and serves as the
  default locale list for all events in the resource.

  ## Usage in Resource DSL

      dispatch do
        locales ["sv", "en", "no"],
          default_locale: "sv",
          locale_from: :visitor_locale

        event :created, trigger_on: :create do
          channels [
            [transport: :email, audience: :customer],
            [transport: :email, audience: :admin, locale: "sv"]
          ]
        end
      end

  ## Fields

  - `locales` - List of locale codes (e.g., `["sv", "en"]`). Templates will be
    generated for each locale when running `mix ash.codegen`.

  - `default_locale` - Fallback locale when none can be determined from the record.
    Falls back to `AshDispatch.Config.default_locale()` if not set.

  - `locale_from` - Atom field name on the resource to read runtime locale from.
    At dispatch time, this field is read from the record to determine which
    locale-specific template to render.

  ## Locale Resolution Priority

  1. Channel-level `locale` (static override)
  2. Channel-level `locale_from` (dynamic from record)
  3. Event-level `locale_from`
  4. Resource-level `locale_from` (this config)
  5. Auto-detected common fields: `:visitor_locale`, `:locale`
  6. Config default (`AshDispatch.Config.default_locale()`)

  ## Template Fallback Chain

  When resolving templates, AshDispatch tries these in order:

  1. `email.admin.sv.html.heex` (variant + locale)
  2. `email.admin.html.heex` (variant only)
  3. `email.sv.html.heex` (locale only)
  4. `email.html.heex` (base template)
  5. `default.sv.html.heex` (default + locale)
  6. `default.html.heex` (ultimate fallback)
  """

  defstruct [
    :locales,
    :default_locale,
    :locale_from,
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{
          locales: [String.t()],
          default_locale: String.t() | nil,
          locale_from: atom() | nil,
          __spark_metadata__: any()
        }
end
