defmodule Garden.Socket.State do
  @moduledoc """
  Pure state transition functions for Garden.Socket.

  Each function takes relevant state and returns a result without
  performing side effects. The socket callbacks are thin wrappers
  that call these functions and execute the returned effects.
  """

  alias SowerClient.Orchestration.DeploymentRequest

  def build_seed_report(
        subscriptions,
        collect_profiles_fun \\ &Garden.Profile.collect_profiles_for_subscriptions/1
      ) do
    report = collect_profiles_fun.(subscriptions)

    if not Enum.empty?(subscriptions) and Enum.empty?(report.profiles) do
      :no_profiles
    else
      {:report, report}
    end
  end

  def build_deployment_request(sid, force?) do
    payload = %{subscription_sids: [sid]}

    payload =
      if force? do
        Map.put(payload, :force, true)
      else
        payload
      end

    DeploymentRequest.new(payload)
  end
end
