defmodule Sower.AccountsTest do
  use Sower.DataCase

  import Sower.AccountsFixtures
  alias Sower.Accounts.{User, UserToken}

  setup _ do
    org = organization_fixture()
    Sower.Repo.put_org_id(org.org_id)
    %{organization: org}
  end

  describe "get_by_id!/1" do
    test "raises if id is invalid" do
      assert_raise Ecto.NoResultsError, fn ->
        User.get_by_sid!(SowerClient.Schemas.Sid.generate())
      end
    end

    test "returns the user with the given id" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = User.get_by_id!(user.id)
    end
  end

  describe "new/1" do
    test "validates email uniqueness", %{organization: org} do
      %{email: email} = user_fixture()

      {:error, changeset} =
        User.new(%{
          email: email,
          name: "Jane Doe",
          oidc_id: Ecto.UUID.generate(),
          org_id: org.org_id
        })

      assert "has already been taken" in errors_on(changeset).email

      # Now try with the upper cased email too, to check that email case is ignored.
      {:error, changeset} =
        User.new(%{
          email: String.upcase(email),
          name: "Jack Doe",
          oidc_id: Ecto.UUID.generate(),
          org_id: org.org_id
        })

      assert "has already been taken" in errors_on(changeset).email
    end
  end

  describe "generate_session_token/1" do
    setup do
      %{user: user_fixture()}
    end

    test "generates a token", %{user: user, organization: org} do
      token = User.generate_session_token(user)
      assert user_token = Repo.get_by(UserToken, [token: token], skip_org_id: true)
      assert user_token.context == "session"

      # Creating the same token for another user should fail
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%UserToken{
          token: user_token.token,
          user_id: user_fixture().id,
          context: "session",
          org_id: org.org_id
        })
      end
    end
  end

  describe "get_by_session_token/1" do
    setup do
      user = user_fixture()
      token = User.generate_session_token(user)
      %{user: user, token: token}
    end

    test "returns user by token", %{user: user, token: token} do
      assert session_user = User.get_by_session_token(token)
      assert session_user.id == user.id
    end

    test "does not return user for invalid token" do
      refute User.get_by_session_token("oops")
    end

    test "does not return user for expired token", %{token: token} do
      {1, nil} =
        Repo.update_all(UserToken, [set: [inserted_at: ~N[2020-01-01 00:00:00]]],
          skip_org_id: true
        )

      refute User.get_by_session_token(token)
    end
  end

  describe "delete_session_token/1" do
    test "deletes the token" do
      user = user_fixture()
      token = User.generate_session_token(user)
      assert User.delete_session_token(token) == :ok
      refute User.get_by_session_token(token)
    end
  end
end
