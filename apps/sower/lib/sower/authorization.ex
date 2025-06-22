defmodule Sower.Authorization do
  use Permit, permissions_module: Sower.Authorization.Permissions
end
