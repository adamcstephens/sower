defmodule VMManager.ActivatorClient do
  @moduledoc false

  def network(action, options) do
    id = SowerClient.Sid.generate("net")

    request = %{
      "id" => id,
      "type" => "network",
      "network_action" => to_string(action),
      "execution_id" => options[:execution_id],
      "lease" => options[:lease]
    }

    case :gen_tcp.connect(
           {:local, options[:socket_path]},
           0,
           [:binary, active: false, packet: :line, packet_size: 65_536],
           5_000
         ) do
      {:ok, socket} ->
        try do
          with :ok <- :gen_tcp.send(socket, [Jason.encode!(request), "\n"]),
               {:ok, output} <- responses(socket, id, []) do
            result(action, output)
          else
            {:error, reason} -> {:error, reason}
          end
        after
          :gen_tcp.close(socket)
        end

      {:error, :enoent} ->
        {:error, :socket_not_found}

      {:error, :econnrefused} ->
        {:error, :connection_refused}

      {:error, reason} ->
        {:error, {:connect_failed, reason}}
    end
  end

  defp responses(socket, id, output) do
    with {:ok, line} <- :gen_tcp.recv(socket, 0, 5_000),
         {:ok, response} <- Jason.decode(line) do
      case response do
        %{"id" => ^id, "type" => "output", "data" => data} ->
          responses(socket, id, [data | output])

        %{"id" => ^id, "type" => "error", "data" => data} ->
          responses(socket, id, [data | output])

        %{"id" => ^id, "type" => "complete", "exit_code" => 0} ->
          {:ok, Enum.reverse(output)}

        %{"id" => ^id, "type" => "complete", "exit_code" => code} ->
          {:error, {:activation_failed, code, Enum.reverse(output)}}

        _ ->
          {:error, :invalid_network_response}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp result(:provision, [data]) do
    with {:ok, json} <- Jason.decode(data),
         {:ok, lease} <- SowerClient.Activator.NetworkLease.cast(json) do
      {:ok, lease}
    else
      {:error, reason} -> {:error, {:network_protocol, reason}}
    end
  end

  defp result(:provision, _), do: {:error, {:network_protocol, :missing_lease}}
  defp result(_, _), do: :ok
end
