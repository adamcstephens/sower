defmodule Sower.Repo.Seeds.Preseed do
  alias Sower.Repo.Seeds.Org

  require Logger

  def for_e2e() do
    Application.load(:sower)

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Sower.Repo, fn repo ->
        user = Org.new_org_and_user(%Org{name: "testing organization", email: "test@sower.dev"})

        access_token = Org.access_token(user)

        File.write!(token_file(), access_token.token)
        Logger.info("Wrote #{token_file()}")
      end)
  end

  defp token_file() do
    out_dir =
      if File.dir?("/run/sower") do
        "/run/sower"
      else
        File.mkdir_p!("/tmp/sower")
        "/tmp/sower"
      end

    "#{out_dir}/test_token"
  end
end
