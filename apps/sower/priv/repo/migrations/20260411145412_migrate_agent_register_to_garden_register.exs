defmodule Sower.Repo.Migrations.MigrateAgentRegisterToGardenRegister do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE access_tokens
    SET permissions = (
      SELECT jsonb_agg(
        CASE
          WHEN elem->>'role' = 'agent:register'
          THEN jsonb_set(elem, '{role}', '"garden:register"')
          ELSE elem
        END
      )
      FROM jsonb_array_elements(permissions) AS elem
    )
    WHERE permissions::text LIKE '%agent:register%'
    """)
  end

  def down do
    :ok
  end
end
