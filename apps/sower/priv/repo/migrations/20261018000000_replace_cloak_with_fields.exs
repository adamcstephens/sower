defmodule Sower.Repo.Migrations.ReplaceCloakWithFields do
  use Ecto.Migration

  import Ecto.Query

  def up do
    key = Application.fetch_env!(:sower, :database) |> Keyword.fetch!(:encryption_key)

    for {table, columns} <- [
          {"forges", [:client_id, :client_secret]},
          {"repositories", [:webhook_secret]}
        ],
        column <- columns do
      query =
        from(row in table,
          where: not is_nil(field(row, ^column)),
          select: {row.id, field(row, ^column)}
        )

      query
      |> repo().stream(skip_org_id: true)
      |> Enum.each(fn {id, value} ->
        converted = convert(value, key)

        from(row in table, where: row.id == ^id)
        |> repo().update_all([set: [{column, converted}]], skip_org_id: true)
      end)
    end
  end

  def down do
    raise Ecto.MigrationError, "the Fields encryption migration is forward-only; restore a backup"
  end

  defp convert(
         <<1, 10, "AES.GCM.V1", iv::binary-16, tag::binary-16, ciphertext::binary>>,
         key
       ) do
    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           key,
           iv,
           ciphertext,
           "AES256GCM",
           tag,
           false
         ) do
      plaintext when is_binary(plaintext) -> "0000" <> iv <> tag <> ciphertext
      :error -> raise Ecto.MigrationError, "legacy ciphertext authentication failed"
    end
  end
end
