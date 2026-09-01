defmodule SowerWeb.Api.DeploymentJSON do
  alias Sower.Orchestration.Deployment

  @doc """
  Renders a deployment for polling.
  """
  def show(%{deployment: %Deployment{} = deployment, skipped: skipped}) do
    %{
      sid: deployment.sid,
      garden_sid: deployment.garden.sid,
      state: deployment.state,
      result: deployment.result,
      deployed_at: deployment.deployed_at,
      skipped: skipped,
      seeds: Enum.map(deployment.seed_deployments, &seed_info/1)
    }
  end

  def error(%{error: error}) do
    %{error: error}
  end

  defp seed_info(seed_deployment) do
    %{
      seed_sid: seed_deployment.seed.sid,
      name: seed_deployment.seed.name,
      seed_type: seed_deployment.seed.seed_type,
      state: seed_deployment.state,
      result: seed_deployment.result,
      log: seed_deployment.log
    }
  end
end
