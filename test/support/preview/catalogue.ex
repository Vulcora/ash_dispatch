defmodule AshDispatch.Test.Preview.Catalogue do
  @moduledoc false
  # A consumer's event catalogue with the library's default policies: through
  # the configured `permission_checker`.
  use AshDispatch.Resources.EventCatalogue.Base,
    domain: AshDispatch.Test.Preview.Domain,
    permission: :view_event_catalogue
end

defmodule AshDispatch.Test.Preview.OwnPolicyCatalogue do
  @moduledoc false
  # The same catalogue with `policies: :own` and a bypass of the host's own —
  # which is the whole point of the macro.
  use AshDispatch.Resources.EventCatalogue.Base,
    domain: AshDispatch.Test.Preview.Domain,
    policies: :own

  policies do
    bypass actor_attribute_equals(:librarian, true) do
      authorize_if always()
    end
  end
end

defmodule AshDispatch.Test.Preview.EmailOnlyCatalogue do
  @moduledoc false
  # Email only, no previews — a catalogue that wants names and channels.
  use AshDispatch.Resources.EventCatalogue.Base,
    domain: AshDispatch.Test.Preview.Domain,
    transports: [:email],
    previews?: false
end

defmodule AshDispatch.Test.Preview.Librarian do
  @moduledoc false
  # A host's permission checker, the shape `config :ash_dispatch,
  # permission_checker:` expects: an `Ash.Policy.Check` with a `match?/3` that
  # `AshDispatch.PolicyChecks.HasPermission` delegates to.
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(opts), do: "holds #{inspect(opts[:permission])}"

  @impl true
  def match?(%{permissions: permissions}, _context, opts) when is_list(permissions) do
    opts[:permission] in permissions
  end

  def match?(_actor, _context, _opts), do: false
end
