defmodule Sower.Permissions do
  use Permit.Permissions, actions_module: Permit.Phoenix.Actions

  def can(user), do: permit()
end
