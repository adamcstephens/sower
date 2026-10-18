defmodule Sower.Accounts.AccessTokenTest do
  use Sower.DataCase

  alias Sower.Accounts.AccessToken

  import Sower.AccountsFixtures

  test "existing Argon2i access tokens still authenticate after the dependency cutover" do
    user = user_fixture()

    token =
      Repo.insert!(%AccessToken{
        user_id: user.id,
        org_id: user.org_id,
        description: "legacy token",
        expires_at: Date.add(Date.utc_today(), 1),
        token_hash:
          "$argon2i$v=19$m=19456,t=2,p=1$/MFc2cgfGBSFcCWTaR5SLw$C2TReWm4shOfz1S0TPe9XEjDcpVv9x0AttL0U4rG+aA"
      })

    assert {:ok, authenticated} =
             AccessToken.authenticate("sower_#{token.sid}_legacy-access-token-secret")

    assert authenticated.id == token.id

    assert {:error, "Invalid token: Hash Verify Failure"} =
             AccessToken.authenticate("sower_#{token.sid}_incorrect-access-token-secret")
  end

  test "new access tokens authenticate and regeneration invalidates the previous secret" do
    token = access_token_fixture()
    assert {:ok, authenticated} = AccessToken.authenticate(token.token)
    assert authenticated.id == token.id

    assert {:ok, regenerated} = AccessToken.update(token, %{"regenerate" => true})
    assert {:error, "Invalid token: Hash Verify Failure"} = AccessToken.authenticate(token.token)
    assert {:ok, authenticated} = AccessToken.authenticate(regenerated.token)
    assert authenticated.id == token.id
  end
end
