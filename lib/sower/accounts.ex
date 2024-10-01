defmodule Sower.Accounts do
  import Ecto.Query

  alias Sower.Accounts.{Organization, User}
  alias Sower.Repo

  # TODO upsert attrs to sync from OIDC provider
  def find_or_create_user(
        oidc_id,
        %Ueberauth.Auth.Info{
          name: name,
          email: email
        }
      ) do
    case Repo.get_by(User, [oidc_id: oidc_id], skip_org_id: true) do
      nil ->
        {:ok, organization} = Organization.create(%{name: name})

        %User{oidc_id: oidc_id}
        |> User.changeset(%{
          oidc_id: oidc_id,
          org_id: organization.org_id,
          name: name,
          email: email
        })
        |> Repo.insert()

      user ->
        {:ok, user}
    end
  end

  def list_user_access_tokens(user_id) do
    query =
      from a in Sower.Accounts.AccessToken,
        where: a.user_id == ^user_id

    Repo.all(query, skip_org_id: true)
  end
end
