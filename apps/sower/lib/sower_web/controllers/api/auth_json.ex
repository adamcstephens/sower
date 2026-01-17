defmodule SowerWeb.Api.AuthJSON do
  def show(%{access_token: access_token}) do
    %{
      sid: access_token.sid,
      description: access_token.description,
      permissions: Enum.map(access_token.permissions, &Atom.to_string(&1.role)),
      expires_at: Date.to_iso8601(access_token.expires_at)
    }
  end
end
