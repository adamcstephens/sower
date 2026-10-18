unless Code.ensure_loaded?(Sower.Repo.Migrations.ReplaceCloakWithFields) do
  Code.require_file(
    "../../priv/repo/migrations/20261018000000_replace_cloak_with_fields.exs",
    __DIR__
  )
end

defmodule Sower.EncryptionMigrationTest do
  use Sower.DataCase

  alias Sower.Forge.{Connection, Repository}
  alias Sower.Repo.Migrations.ReplaceCloakWithFields

  import Sower.AccountsFixtures
  import Sower.ForgeFixtures

  @legacy Base.decode64!(
            "AQpBRVMuR0NNLlYxwETvc9gzSRG/vP6U82VsxrL9tYaHL1YAzaXICegfM2q6mpyeP//IrigoC8d1"
          )

  test "migrates credentials across tenants and preserves nullable webhook secrets" do
    connections =
      for _ <- 1..2 do
        org = organization_fixture()
        Repo.put_org_id(org.org_id)
        connection = connection_fixture()

        repository =
          Repo.insert!(%Repository{
            forge_id: connection.id,
            org_id: org.org_id,
            owner: "owner",
            repo: "repo",
            url: "https://example.org/repo"
          })

        set_legacy(connection.id, :client_id, @legacy)
        set_legacy(connection.id, :client_secret, @legacy)

        from(row in "repositories", where: row.id == ^repository.id)
        |> Repo.update_all([set: [webhook_secret: @legacy]], skip_org_id: true)

        Repo.insert!(%Repository{
          forge_id: connection.id,
          org_id: org.org_id,
          owner: "owner",
          repo: "nullable",
          url: "https://example.org/nullable"
        })

        {connection, repository}
      end

    Repo.put_org_id(nil)
    Repo.transaction(fn -> migrate() end)

    for {connection, repository} <- connections do
      loaded = Repo.get!(Connection, connection.id, skip_org_id: true)
      assert loaded.client_id == "legacy-secret"
      assert loaded.client_secret == "legacy-secret"

      assert Repo.get!(Repository, repository.id, skip_org_id: true).webhook_secret ==
               "legacy-secret"
    end

    assert Repo.all(
             from(row in Repository, where: row.repo == "nullable", select: row.webhook_secret),
             skip_org_id: true
           ) == [nil, nil]

    {connection, _} = hd(connections)
    loaded = Repo.get!(Connection, connection.id, skip_org_id: true)
    updated = loaded |> Ecto.Changeset.change(client_secret: "new-secret") |> Repo.update!()
    assert Repo.get!(Connection, updated.id, skip_org_id: true).client_secret == "new-secret"

    [[stored]] = Repo.query!("SELECT client_secret FROM forges WHERE id = $1", [updated.id]).rows
    assert Fields.AES.decrypt(stored) == "new-secret"
  end

  test "authentication failure rolls back already converted columns" do
    org = organization_fixture()
    Repo.put_org_id(org.org_id)
    connection = connection_fixture()
    set_legacy(connection.id, :client_id, @legacy)
    <<prefix::binary-size(byte_size(@legacy) - 1), last>> = @legacy
    set_legacy(connection.id, :client_secret, prefix <> <<Bitwise.bxor(last, 1)>>)

    assert_raise Ecto.MigrationError, "legacy ciphertext authentication failed", fn ->
      Repo.transaction(fn -> migrate() end, mode: :savepoint)
    end

    [[stored]] = Repo.query!("SELECT client_id FROM forges WHERE id = $1", [connection.id]).rows
    assert stored == @legacy
  end

  test "rollback requires restoring a backup" do
    assert_raise Ecto.MigrationError, ~r/forward-only/, &ReplaceCloakWithFields.down/0
  end

  defp set_legacy(id, column, value) do
    from(row in "forges", where: row.id == ^id)
    |> Repo.update_all([set: [{column, value}]], skip_org_id: true)
  end

  defp migrate do
    Ecto.Migration.Runner.run(
      Repo,
      Repo.config(),
      20_261_018_000_000,
      ReplaceCloakWithFields,
      :forward,
      :up,
      :up,
      log: false
    )
  end
end
