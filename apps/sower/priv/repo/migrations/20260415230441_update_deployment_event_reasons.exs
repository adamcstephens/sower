defmodule Sower.Repo.Migrations.UpdateDeploymentEventReasons do
  use Ecto.Migration

  def up do
    execute("ALTER TYPE deployment_event_reason ADD VALUE IF NOT EXISTS 'user_retry'")
    execute("ALTER TYPE deployment_event_reason ADD VALUE IF NOT EXISTS 'poll_on_connect'")
  end

  def down do
    # PostgreSQL does not support removing enum values.
    # These values are safe to leave in place.
    :ok
  end
end
