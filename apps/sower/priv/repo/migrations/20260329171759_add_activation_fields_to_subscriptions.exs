defmodule Sower.Repo.Migrations.AddActivationFieldsToSubscriptions do
  use Ecto.Migration

  def change do
    alter table(:subscriptions) do
      add :activation_args, {:array, :string}, default: []
      add :reboot_policy, :string, default: "never"
    end
  end
end
