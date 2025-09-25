defmodule Sower.Repo.Seeds.Preseed do
  alias Sower.Repo.Seeds.Org

  require Logger

  def for_e2e() do
    out_dir =
      if File.dir?("/run/sower") do
        "/run/sower"
      else
        File.mkdir_p!("/tmp/sower")
        "/tmp/sower"
      end

    out_file = "#{out_dir}/test_token"

    simple_org_and_key(%Org{name: "testing organization", email: "test@sower.dev"}, out_file)
  end

  def for_dev(email) do
    Application.load(:sower)

    token_file = Path.absname(".dev-api-token")

    Ecto.Migrator.with_repo(Sower.Repo, fn _repo ->
      case Sower.Repo.all_by(Sower.Accounts.User, [email: email], skip_org_id: true) do
        [] ->
          Logger.error(msg: "User for email not found. Did you log in first?")
          Kernel.exit(1)

        [user] ->
          case Sower.Accounts.Organization.list() do
            [_org] ->
              access_token =
                Org.access_token(user, "dev token", %{
                  "expires_at" => Date.add(Date.utc_today(), 30)
                })

              File.write!(token_file, access_token.token)
              Logger.info("Wrote #{token_file}")

            orgs ->
              Logger.error(
                msg: "Can't handle no organizations or more than one organization.",
                organizations: orgs
              )

              Kernel.exit(1)
          end
      end
    end)
  end

  defp simple_org_and_key(%Org{} = org, token_file) do
    Application.load(:sower)

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Sower.Repo, fn _repo ->
        user = Org.new_org_and_user(org)

        access_token =
          Org.access_token(user, "dev token", %{"expires_at" => Date.add(Date.utc_today(), 30)})

        File.write!(token_file, access_token.token)
        Logger.info("Wrote #{token_file}")
      end)
  end
end
