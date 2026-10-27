defmodule AshDispatch.Test.Preview.ManualTrigger do
  @moduledoc false
  # A consumer's ManualTrigger, opened to everyone — the way an app opens it
  # to its admins.
  use AshDispatch.Resources.ManualTrigger.Base, domain: AshDispatch.Test.Preview.Domain

  policies do
    bypass always() do
      authorize_if always()
    end
  end
end

defmodule AshDispatch.Test.Preview.DenyAll do
  @moduledoc false
  # A preference checker that says no to everyone.
  @behaviour AshDispatch.UserPreference

  @impl true
  def user_allows?(_user_id, _event_id, _transport, _opts), do: false
end
