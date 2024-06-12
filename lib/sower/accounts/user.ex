defmodule Sower.Accounts.User do
  use Ash.Resource,
    domain: Sower.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication]

  actions do
    defaults [:read]

    create :register_with_oidc do
      argument :user_info, :map, allow_nil?: false
      argument :oauth_tokens, :map, allow_nil?: false
      upsert? true
      upsert_identity :unique_oidc_id

      change AshAuthentication.GenerateTokenChange

      change fn changeset, _ctx ->
        user_info = Ash.Changeset.get_argument(changeset, :user_info)

        changeset
        |> Ash.Changeset.change_attribute(:oidc_id, user_info["sub"])
        |> Ash.Changeset.change_attribute(:username, user_info["preferred_username"])
      end
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :oidc_id, :uuid do
      allow_nil? false
    end

    attribute :username, :ci_string do
      allow_nil? false
      public? true
    end
  end

  authentication do
    strategies do
      oidc :oidc do
        client_id Sower.Accounts.Secrets

        base_url fn _, _ ->
          case Application.get_env(:sower, :auth) |> Keyword.get(:oidc_base_url) do
            nil -> :error
            val -> {:ok, val}
          end
        end

        redirect_uri fn _, _ ->
          case Application.get_env(:sower, :auth) |> Keyword.get(:oidc_redirect_uri) do
            nil -> :error
            val -> {:ok, val}
          end
        end

        client_secret Sower.Accounts.Secrets
        # TODO: figure out why decoding fails with ES256
        # id_token_signed_response_alg "ES256"
        # authorization_params scope: "openid profile email"
      end
    end

    tokens do
      token_resource Sower.Accounts.UserToken
      signing_secret Sower.Accounts.Secrets
    end
  end

  postgres do
    table "users"
    repo Sower.Repo
  end

  identities do
    identity :unique_oidc_id, [:oidc_id]
  end
end
