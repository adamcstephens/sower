defmodule Sower.Accounts do
  import Ecto.Query

  alias Sower.Accounts.{Organization, User}
  alias Sower.Repo

  defp find_or_create_org_default(user_name) do
    case Application.get_env(:sower, :organization, %{
           mode: "single",
           name: "default organization"
         }) do
      %{mode: "single", name: org_name} ->
        case Sower.Accounts.Organization
             |> Sower.Repo.get_by([name: org_name], skip_org_id: true) do
          nil ->
            Organization.create(%{name: org_name})

          org ->
            {:ok, org}
        end

      %{mode: "single"} ->
        raise "single organization mode requires a name"

      %{mode: "multi"} ->
        Organization.create(%{name: user_name})
    end
  end

  # TODO upsert attrs to sync from OIDC provider
  def find_or_create_user(
        oidc_id,
        %Ueberauth.Auth.Info{
          name: name,
          email: email
        }
      ) do
    case Repo.get_by(User, [oidc_id: oidc_id], skip_org_id: true) |> dbg() do
      nil ->
        {:ok, organization} = find_or_create_org_default(name)

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
