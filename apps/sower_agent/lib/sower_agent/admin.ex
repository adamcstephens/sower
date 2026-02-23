defmodule SowerAgent.Admin do
  @moduledoc """
  Admin tools for the agent. Useful on local repl
  """

  require Logger

  import SowerClient.Seed, only: [is_seed_type?: 1]

  def subs(seed_type) do
    SowerAgent.Storage.read().subscriptions
    |> Enum.filter(&(&1.seed_type == seed_type))
  end

  def deploy(seed_type) when is_atom(seed_type) do
     seed_type |> String.to_existing_atom() |> deploy()
   end

  def deploy(seed_type) when is_seed_type?(seed_type) do
    case subs(seed_type) do
      [] ->
        Logger.error(msg: "nixos subscription not found")
        {:error, :subscription_not_found}

      [sub] ->
        SowerAgent.Client.deploy(sub)

      [_ | _] ->
        Logger.error(msg: "too many nixos subscriptions found")
        {:error, :too_many_results}
    end
  end
end
