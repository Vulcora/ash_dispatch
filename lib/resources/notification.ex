defmodule AshDispatch.Resources.Notification do
  @moduledoc """
  Default notification resource for AshDispatch.

  This is a reference implementation using the Base module. Most consuming apps
  should create their own Notification resource to add relationships to their
  User resource:

      defmodule MyApp.Notifications.Notification do
        use AshDispatch.Resources.Notification.Base,
          repo: MyApp.Repo,
          domain: MyApp.Notifications

        # Add user relationship
        relationships do
          belongs_to :user, MyApp.Accounts.User do
            source_attribute :user_id
            destination_attribute :id
            allow_nil? false
            public? true
          end
        end
      end
  """

  use AshDispatch.Resources.Notification.Base,
    repo: Application.compile_env(:ash_dispatch, :repo, nil),
    domain: AshDispatch.Domain

  typescript do
    type_name("Notification")
  end
end
