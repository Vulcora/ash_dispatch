defmodule Demo.Accounts.User do
  use Ash.Resource, domain: Demo.Accounts, data_layer: AshPostgres.DataLayer

  postgres do
    table "users"
    repo Demo.Repo
  end

  attributes do
    uuid_primary_key :id
    attribute :email, :string, public?: true
  end
end
