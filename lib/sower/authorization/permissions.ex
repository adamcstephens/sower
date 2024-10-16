defmodule Sower.Authorization.Permissions do
  use Permit.Permissions, actions_module: Sower.Authorization.Actions

  def can(%Sower.Accounts.AccessToken{} = token) do
    permit()
    |> map_permissions(token |> Sower.Repo.preload(:user))
  end

  # block by default
  def can(_), do: permit()

  defp map_permissions(permit, token) do
    Enum.reduce(token.permissions, permit, fn permission, permit ->
      permit
      |> permission_to(permission.action, permission.resource, org_id: token.user.org_id)
    end)
  end
end
