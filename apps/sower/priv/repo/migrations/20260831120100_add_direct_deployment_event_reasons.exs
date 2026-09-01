defmodule Sower.Repo.Migrations.AddDirectDeploymentEventReasons do
  use Ecto.Migration

  def up do
    execute("ALTER TYPE deployment_event_reason ADD VALUE IF NOT EXISTS 'direct_triggered'")
    execute("ALTER TYPE deployment_event_reason ADD VALUE IF NOT EXISTS 'direct_override'")
  end

  def down do
    # PostgreSQL does not support removing enum values.
    # These values are safe to leave in place.
    :ok
  end
end
