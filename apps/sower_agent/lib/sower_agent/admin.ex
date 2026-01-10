defmodule SowerAgent.Admin do
  @moduledoc """
  Admin tools for the agent. Useful on local repl
  """

  def latest(:nixos) do
    SowerAgent.Storage.read().subscriptions |> Enum.find(&(&1.seed_type == "nixos"))
  end

  def deploy(:nixos) do
    case latest(:nixos) do
      nil -> :error
      sub -> SowerAgent.Client.deploy(sub)
    end
  end
end
