defmodule AshDispatch.Event.Helpers do
  @moduledoc """
  Helper functions for events that use Ash introspection to derive behavior.

  These helpers enable zero-configuration recipient resolution by:
  - Introspecting Ash resources to find user relationships
  - Querying configured User module for admins
  - Extracting users from context automatically

  ## Configuration Required

  In your application config:

      config :ash_dispatch,
        user_module: MyApp.Accounts.User,
        admin_filter: [super_admin: true]

  ## How It Works

  **For :admin audience:**
  - Queries user_module with admin_filter
  - Returns list of admin users

  **For :user audience:**
  - Extracts user from context using Ash introspection
  - Follows relationships defined in resources
  - No hardcoded patterns needed

  **For :system audience:**
  - Returns configured system recipients (if any)
  """

  require Logger

  @doc """
  Resolves recipients for a channel based on its audience.

  Uses Ash introspection to automatically find and extract users.

  ## Examples

      # Admin audience - queries admins
      resolve_recipients_for_audience(context, %Channel{audience: :admin})
      # => [%{id: "1", email: "admin@example.com", display_name: "Admin"}]

      # User audience - extracts from context via Ash
      resolve_recipients_for_audience(context, %Channel{audience: :user})
      # => [%{id: "123", email: "user@example.com", display_name: "John"}]
  """
  def resolve_recipients_for_audience(context, channel) do
    case channel.audience do
      :admin -> resolve_admin_recipients()
      :user -> resolve_user_recipient(context)
      :system -> resolve_system_recipients()
      _ -> []
    end
  end

  # Resolve admin recipients by querying User module with admin filter
  defp resolve_admin_recipients do
    user_module = Application.get_env(:ash_dispatch, :user_module)
    admin_filter = Application.get_env(:ash_dispatch, :admin_filter, [])

    if is_nil(user_module) do
      Logger.warning(
        "No :user_module configured in :ash_dispatch config, cannot resolve admin recipients"
      )

      []
    else
      user_module
      |> Ash.Query.filter(^admin_filter)
      |> Ash.Query.select([:id, :email, :display_name, :name])
      |> Ash.read(authorize?: false)
      |> case do
        {:ok, admins} -> Enum.map(admins, &normalize_user/1)
        {:error, error} ->
          Logger.error("Failed to query admin recipients: #{inspect(error)}")
          []
      end
    end
  end

  # Resolve user recipient by extracting from context using Ash introspection
  defp resolve_user_recipient(context) do
    case extract_user_from_context(context) do
      nil -> []
      user -> [normalize_user(user)]
    end
  end

  # Extract user from context using Ash introspection
  # This is the same logic as in Dispatcher but can be called from events
  defp extract_user_from_context(context) do
    user_module = Application.get_env(:ash_dispatch, :user_module)

    if is_nil(user_module) do
      nil
    else
      # Strategy 1: Check if any value in data IS the user module
      Enum.find_value(context.data, fn {_key, value} ->
        if is_struct(value) && value.__struct__ == user_module do
          value
        end
      end) ||
        # Strategy 2: Use Ash introspection to find user via relationships
        find_user_via_ash_relationships(context.data, user_module)
    end
  end

  # Find user by introspecting Ash resource relationships
  defp find_user_via_ash_relationships(data, user_module) do
    Enum.find_value(data, fn {_key, resource} ->
      # Only process Ash resources
      if is_struct(resource) && Ash.Resource.resource?(resource.__struct__) do
        # Get all relationships defined on this resource
        relationships = Ash.Resource.Info.relationships(resource.__struct__)

        # Find any relationship pointing to the configured User module
        user_relationship =
          Enum.find(relationships, fn rel ->
            rel.destination == user_module
          end)

        # Extract user from that relationship if found
        if user_relationship do
          Map.get(resource, user_relationship.name)
        end
      end
    end)
  end

  # Resolve system recipients (optional configuration)
  defp resolve_system_recipients do
    Application.get_env(:ash_dispatch, :system_recipients, [])
  end

  # Normalize user to standard recipient format
  defp normalize_user(%{__struct__: module} = user) do
    # Extract email, handling CiString automatically via Ash introspection
    email = extract_email_field(user, module)

    %{
      id: user.id,
      email: email,
      display_name: user.display_name || Map.get(user, :name) || email
    }
  end

  # Extract email field from user, handling CiString type
  defp extract_email_field(user, module) do
    # Get email attribute definition from Ash resource
    attributes = Ash.Resource.Info.attributes(module)
    email_attr = Enum.find(attributes, fn attr -> attr.name == :email end)

    if email_attr do
      # Handle different email value types
      case Map.get(user, :email) do
        # CiString with :string field
        %{string: email} when is_binary(email) -> email
        # CiString with :data field (Cldr.LanguageTag.CiString)
        %{data: email} when is_binary(email) -> email
        # Plain binary string
        email when is_binary(email) -> email
        # Fallback
        _ -> nil
      end
    else
      nil
    end
  end
end
