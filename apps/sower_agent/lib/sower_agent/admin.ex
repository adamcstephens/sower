defmodule SowerAgent.Admin do
  @moduledoc """
  Admin tools for the agent. Useful on local repl
  """

  require Logger

  def subs(:nixos) do
    SowerAgent.Storage.read().subscriptions |> Enum.filter(&(&1.seed_type == "nixos"))
  end

  def deploy(:nixos) do
    case subs(:nixos) do
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
