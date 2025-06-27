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
    name = email |> String.split("@") |> List.first()

    simple_org_and_key(%Org{name: name, email: email}, Path.absname(".dev-api-token"))
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
