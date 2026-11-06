defmodule AshDispatch.PolicyChecks.PreferenceWriter do
  @moduledoc """
  Who may write a notification preference row
  (`AshDispatch.Resources.Preference.Base`).

  - A person's own row (`user_id` is the actor's id): the actor.
  - A tenant default (`user_id` nil): an actor that passes
    `AshDispatch.PolicyChecks.HasPermission` with
    `permission: :manage_notification_preferences` and `tenant:` the row's
    tenant — the app's `:permission_checker` decides, and must check that the
    actor manages *that* tenant. When the action runs with an Ash tenant, the
    row's tenant must also be that tenant.
  - Anyone else's row: nobody.

  For an update or destroy both the stored row and the changed one must
  pass, so a row cannot be moved to someone else.
  """

  use Ash.Policy.SimpleCheck

  @permission :manage_notification_preferences

  @impl true
  def describe(_opts), do: "actor may write this notification preference"

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, %{changeset: %Ash.Changeset{} = changeset} = context, _opts) do
    new_user_id = Ash.Changeset.get_attribute(changeset, :user_id)

    stored_user_id =
      case changeset.data do
        %{__meta__: %{state: :loaded}} = data -> Map.get(data, :user_id)
        _ -> new_user_id
      end

    new_tenant = Ash.Changeset.get_attribute(changeset, :tenant)

    stored_tenant =
      case changeset.data do
        %{__meta__: %{state: :loaded}} = data -> Map.get(data, :tenant)
        _ -> new_tenant
      end

    allowed?(actor, new_user_id, new_tenant, context) and
      allowed?(actor, stored_user_id, stored_tenant, context)
  end

  def match?(_actor, _context, _opts), do: false

  # With an Ash tenant on the action, a default can only be written there.
  defp in_action_tenant?(tenant, %{changeset: %{tenant: action_tenant}})
       when not is_nil(action_tenant) do
    AshDispatch.Context.tenant_key(tenant) == AshDispatch.Context.tenant_key(action_tenant)
  end

  defp in_action_tenant?(_tenant, _context), do: true

  defp allowed?(actor, nil, tenant, context) do
    in_action_tenant?(tenant, context) and
      AshDispatch.PolicyChecks.HasPermission.match?(actor, context,
        permission: @permission,
        tenant: tenant
      )
  end

  defp allowed?(actor, user_id, _tenant, _context) do
    to_string(user_id) == to_string(Map.get(actor, :id))
  end
end
