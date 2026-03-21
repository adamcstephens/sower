defmodule Sower.Authorization.Permissions do
  use Permit.Permissions, actions_module: Sower.Authorization.Actions

  def can(%Sower.Accounts.AccessToken{} = token) do
    permit()
    |> map_token_permissions(token |> Sower.Repo.preload(:user))
  end

  # block by default
  def can(_), do: permit()

  defp map_token_permissions(
         %Permit.Permissions{} = permit,
         %Sower.Accounts.AccessToken{} = token
       ) do
    Enum.reduce(token.permissions, permit, fn permission, permit ->
      permit
      |> check_role_perm(permission, token.user.org_id)
    end)
  end

  defp check_role_perm(
         %Permit.Permissions{} = permit,
         %Sower.Accounts.AccessToken.Permission{role: :"nix-cache:read"},
         org_id
       ) do
    permit
    |> read(Sower.Nix.Cache, org_id: org_id)
  end

  defp check_role_perm(
         %Permit.Permissions{} = permit,
         %Sower.Accounts.AccessToken.Permission{role: :"seed:read"},
         org_id
       ) do
    permit
    |> read(Sower.Orchestration.Seed, org_id: org_id)
    |> read(Sower.Nix.Cache, org_id: org_id)
  end

  defp check_role_perm(
         %Permit.Permissions{} = permit,
         %Sower.Accounts.AccessToken.Permission{role: :"seed:write"},
         org_id
       ) do
    permit
    |> all(Sower.Orchestration.Seed, org_id: org_id)
    |> read(Sower.Nix.Cache, org_id: org_id)
  end

  defp check_role_perm(
         %Permit.Permissions{} = permit,
         %Sower.Accounts.AccessToken.Permission{role: :"garden:register"},
         org_id
       ) do
    permit
    |> all(Sower.Orchestration.Garden, org_id: org_id)
  end

  defp check_role_perm(
         %Permit.Permissions{} = permit,
         %Sower.Accounts.AccessToken.Permission{role: :"agent:register"},
         org_id
       ) do
    permit
    |> all(Sower.Orchestration.Garden, org_id: org_id)
  end
end
