defmodule SowerWeb.DeploymentLive.Index do
  use SowerWeb, :live_view

  alias Sower.Orchestration
  alias Sower.Orchestration.Deployment

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Sower.PubSub, "deployments")
    end

    {:ok,
     socket
     |> assign(:page_title, "Listing Deployments")
     |> assign(:retrying_deployment_sid, nil)}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    case Deployment.list_flop(params) do
      {:ok, {deployments, meta}} ->
        {:noreply, assign(socket, deployments: deployments, meta: meta)}

      {:error, meta} ->
        {:noreply, assign(socket, deployments: [], meta: meta)}
    end
  end

  @impl Phoenix.LiveView
  def handle_info({:deployment, :created, deployment}, socket) do
    deployment = Sower.Repo.preload(deployment, [:garden, :events])
    deployments = [deployment | socket.assigns.deployments]
    {:noreply, assign(socket, :deployments, deployments)}
  end

  def handle_info({:deployment, :updated, deployment}, socket) do
    deployment = Sower.Repo.preload(deployment, [:garden, :events])

    deployments =
      Enum.map(socket.assigns.deployments, fn d ->
        if d.id == deployment.id, do: deployment, else: d
      end)

    {:noreply, assign(socket, :deployments, deployments)}
  end

  @impl Phoenix.LiveView
  def handle_event("filter", params, socket) do
    filters =
      []
      |> maybe_add_filter(:garden_name, :ilike_and, params["garden_name"])
      |> maybe_add_filter(:state, :==, params["state"])
      |> maybe_add_filter(:result, :==, params["result"])

    flop = %Flop{filters: filters}
    path = Flop.Phoenix.build_path(~p"/deployments", flop)

    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("retry", %{"sid" => sid}, socket) do
    deployment = Orchestration.get_deployment_sid(sid)

    cond do
      is_nil(deployment) ->
        {:noreply, put_flash(socket, :error, "Deployment not found")}

      not retryable?(deployment) ->
        {:noreply,
         socket
         |> assign(:retrying_deployment_sid, nil)
         |> put_flash(:error, "Only successful or failed deployments can be retried")}

      true ->
        socket = assign(socket, :retrying_deployment_sid, sid)

        case Orchestration.retry_deployment(deployment, socket.assigns.current_user.id) do
          {:ok, _new_deployment} ->
            {:noreply,
             socket
             |> assign(:retrying_deployment_sid, nil)
             |> put_flash(:info, "Retry deployment created")}

          {:error, :retry_in_progress} ->
            {:noreply,
             socket
             |> assign(:retrying_deployment_sid, nil)
             |> put_flash(:error, "A retry is already in progress for this deployment")}

          {:error, _reason} ->
            {:noreply,
             socket
             |> assign(:retrying_deployment_sid, nil)
             |> put_flash(:error, "Failed to retry deployment")}
        end
    end
  end

  defp retryable?(deployment) do
    deployment.state in [:completed, :stale, :canceled]
  end

  defp maybe_add_filter(filters, _field, _op, nil), do: filters
  defp maybe_add_filter(filters, _field, _op, ""), do: filters

  defp maybe_add_filter(filters, field, op, value) do
    filters ++ [%Flop.Filter{field: field, op: op, value: value}]
  end

  defp filter_value(%Flop.Meta{flop: %Flop{filters: filters}}, field) do
    case Enum.find(filters, &(&1.field == field)) do
      %Flop.Filter{value: value} when is_atom(value) and not is_nil(value) ->
        Atom.to_string(value)

      %Flop.Filter{value: value} ->
        value

      nil ->
        nil
    end
  end

  defp filter_value(_meta, _field), do: nil

  defp trigger_label(deployment) do
    created_event = Enum.find(deployment.events, &(&1.event == :created))

    case get_in(created_event.reason) do
      :user_triggered -> "user"
      :schedule_triggered -> "schedule"
      :realtime_triggered -> "realtime"
      :retry -> "retry"
      _ -> "-"
    end
  end

  defp state_options do
    ["created", "dispatched", "acknowledged", "completed", "stale", "canceled"]
  end

  defp result_options do
    ["success", "failure", "partial"]
  end
end
