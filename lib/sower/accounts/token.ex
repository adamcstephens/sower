defmodule Sower.Accounts.UserToken do
  use Ash.Resource,
    domain: Sower.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication.TokenResource]

  postgres do
    table "user_tokens"
    repo Sower.Repo
  end
end
