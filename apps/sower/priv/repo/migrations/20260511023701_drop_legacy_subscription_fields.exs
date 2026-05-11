defmodule Sower.Repo.Migrations.DropLegacySubscriptionFields do
  use Ecto.Migration

  def up do
    alter table(:subscriptions) do
      remove :reboot_policy
      remove :allow_realtime
      remove :window
      remove :activation_args
    end
  end

  def down do
    raise Ecto.MigrationError,
      message: "drop_legacy_subscription_fields is one-way; old fields cannot be restored"
  end
end
