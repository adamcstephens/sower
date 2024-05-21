defmodule Sower.Accounts do
  use Ash.Domain

  resources do
    resource Sower.Accounts.User
    resource Sower.Accounts.UserToken
  end
end
