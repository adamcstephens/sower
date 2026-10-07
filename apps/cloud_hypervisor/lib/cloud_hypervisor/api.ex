defmodule CloudHypervisor.API do
  @moduledoc """
  Explicit client for the Cloud Hypervisor 53.0 Unix-socket HTTP API.

  Construct `%CloudHypervisor.API{socket: "/path/to/vmm.sock"}` per VMM.
  `timeout` bounds connection, pool wait, and response waits in milliseconds.
  Requests never retry or follow redirects. Mutations return `:ok`; reads
  return `{:ok, %Ping{}}` or `{:ok, %Info{}}`. Failures return `{:error, %Error{}}`.
  Pool-checkout timeouts are transport errors with
  `reason: {:pool_timeout, exception}`, retaining Finch's original failure detail.
  Unrelated exceptions propagate.

  `create/2` accepts the shared `CloudHypervisor.Config` direct-boot contract.
  `shutdown/1` stops the VM, not the VMM process and not a guest power-button
  request. `shutdown_vmm/1` exits the VMM.
  """

  use TypedStruct

  alias CloudHypervisor.Config

  typedstruct do
    field :socket, String.t(), enforce: true
    field :timeout, pos_integer(), default: 5_000
  end

  typedstruct module: Ping do
    field :version, String.t(), enforce: true
    field :build_version, String.t(), enforce: true
    field :pid, integer(), enforce: true
    field :features, [String.t()], enforce: true
  end

  typedstruct module: Info do
    field :config, map(), enforce: true
    field :state, String.t(), enforce: true
    field :memory_actual_size, non_neg_integer(), enforce: true
    field :device_tree, map() | nil
  end

  typedstruct module: Error do
    field :kind, :http | :transport | :decode, enforce: true
    field :status, integer() | nil
    field :body, term()
    field :reason, term()
  end

  def ping(%__MODULE__{} = client), do: request(client, :get, "vmm.ping", :ping)
  def info(%__MODULE__{} = client), do: request(client, :get, "vm.info", :info)

  def create(%__MODULE__{} = client, %Config{} = config),
    do: request(client, :put, "vm.create", :empty, json: Config.to_api(config))

  def boot(%__MODULE__{} = client), do: request(client, :put, "vm.boot", :empty)
  def shutdown(%__MODULE__{} = client), do: request(client, :put, "vm.shutdown", :empty)
  def delete(%__MODULE__{} = client), do: request(client, :put, "vm.delete", :empty)
  def shutdown_vmm(%__MODULE__{} = client), do: request(client, :put, "vmm.shutdown", :empty)

  defp request(%__MODULE__{} = client, method, endpoint, result, options \\ []) do
    case Req.request(
           [
             method: method,
             url: "http://localhost/api/v1/" <> endpoint,
             unix_socket: client.socket,
             finch: [
               conn_opts: [transport_opts: [timeout: client.timeout]],
               pool_timeout: client.timeout,
               receive_timeout: client.timeout,
               request_timeout: client.timeout
             ],
             retry: false,
             redirect: false,
             decode_body: false
           ] ++ options
         ) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        decode(result, response)

      {:ok, %Req.Response{} = response} ->
        {:error, %Error{kind: :http, status: response.status, body: error_body(response.body)}}

      {:error, reason} ->
        {:error, %Error{kind: :transport, reason: reason}}
    end
  rescue
    error in RuntimeError ->
      case __STACKTRACE__ do
        [{NimblePool, :exit!, 3, _}, {Finch.HTTP1.Pool, :request, 6, _} | _] ->
          if String.starts_with?(
               error.message,
               "Finch was unable to provide a connection within the timeout due to excess queuing"
             ) do
            {:error, %Error{kind: :transport, reason: {:pool_timeout, error}}}
          else
            reraise error, __STACKTRACE__
          end

        _ ->
          reraise error, __STACKTRACE__
      end
  end

  defp decode(:empty, %Req.Response{}), do: :ok

  defp decode(result, %Req.Response{} = response) do
    case Jason.decode(response.body) do
      {:ok, body} ->
        case typed_response(result, body) do
          {:ok, value} ->
            {:ok, value}

          :error ->
            {:error,
             %Error{kind: :decode, status: response.status, body: body, reason: :invalid_response}}
        end

      {:error, reason} ->
        {:error,
         %Error{kind: :decode, status: response.status, body: response.body, reason: reason}}
    end
  end

  defp typed_response(:ping, %{
         "version" => version,
         "build_version" => build,
         "pid" => pid,
         "features" => features
       })
       when is_binary(version) and is_binary(build) and is_integer(pid) and is_list(features) do
    {:ok, %Ping{version: version, build_version: build, pid: pid, features: features}}
  end

  defp typed_response(
         :info,
         %{"config" => config, "state" => state, "memory_actual_size" => size} = body
       )
       when is_map(config) and is_binary(state) and is_integer(size) and size >= 0 do
    {:ok,
     %Info{
       config: config,
       state: state,
       memory_actual_size: size,
       device_tree: body["device_tree"]
     }}
  end

  defp typed_response(_, _), do: :error

  defp error_body(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end
end
