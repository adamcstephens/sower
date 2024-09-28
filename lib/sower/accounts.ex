defmodule Sower.Accounts do
  alias Sower.Repo

  import Ecto.Query

  def list_user_access_tokens(user_id) do
    query =
      from a in Sower.Accounts.AccessToken,
        where: a.user_id == ^user_id

    Repo.all(query)
  end
end
