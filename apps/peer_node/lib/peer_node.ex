defmodule PeerNode do
  require Logger
  use TypedStruct

  typedstruct do
    field :name, String.t()
    field :pid, String.t()
    field :instance, String.t()
  end

  def start(instance) do
    instance_ip = instance_ip(instance)

    allow_boot(instance_ip)
    setup_erl(instance)

    case :peer.start_link(
           %{
             exec:
               {:os.find_executable(~c"incus"),
                Enum.map(
                  [
                    "exec",
                    instance,
                    "--",
                    "/root/erl"
                  ],
                  &to_charlist/1
                )},
             connection: :standardio,
             name: to_charlist(instance),
             host: to_charlist(instance_ip),
             args:
               Enum.map(
                 [
                   "-hosts",
                   :inet.ntoa(central_node_ip()),
                   # TODO move cookie to a file
                   "-setcookie",
                   "#{:erlang.get_cookie()}",
                   "-loader",
                   "inet"
                 ],
                 &to_charlist/1
               )
           }
           # this dbg silences dialyzer...
         ) do
      {_, peer_pid, peer_name} ->
        node = %__MODULE__{
          pid: peer_pid,
          name: peer_name,
          instance: instance
        }

        load_paths(node)

        node

      {:ok, _} ->
        nil

      {:error, _} = err ->
        err
    end
  end

  def stop(%__MODULE__{} = node) do
    :peer.stop(node.pid)
  end

  def restart(node) do
    stop(node)
    start(node.instance)
  end

  def start_garden(%__MODULE__{} = node) do
    set_config(node)

    call(node, Application, :ensure_all_started, [:garden])
  end

  def get_env(%__MODULE__{} = node, name) do
    call(node, Application, :get_env, [
      :garden,
      name
    ])
  end

  def put_env(%__MODULE__{} = node, name, value) do
    call(node, Application, :put_env, [
      :garden,
      name,
      value
    ])
  end

  def set_config(%__MODULE__{} = node) do
    Logger.debug(msg: "Setting configuration")

    put_env(
      node,
      :config,
      Application.get_env(:garden, :config)
    )

    storage_dir = "/tmp/#{node.name}"

    call(node, File, :mkdir_p, [storage_dir])

    put_env(
      node,
      Garden.Storage,
      file: "#{storage_dir}/storage.etf"
    )

    put_env(
      node,
      Garden.Socket,
      uri: "ws://#{:inet.ntoa(central_node_ip())}:7150/garden/websocket",
      reconnect_after_msec: [200, 500, 1000, 2000]
    )
  end

  def call(%__MODULE__{} = node, module, method, args) do
    :rpc.block_call(node.name, module, method, args)
  end

  def instance_ip(instance) do
    {:ok, state} =
      IncusClient.ApiClient.get("/1.0/instances/{name}/state",
        name: instance,
        project: "sowerdev"
      )

    state.metadata.network
    |> Enum.reject(fn {n, _} -> String.starts_with?(n, "lo") end)
    |> List.first()
    |> elem(1)
    |> Map.get(:addresses)
    # grab the first ipv4
    |> Enum.find(fn a -> a.family == "inet" end)
    |> Map.get(:address)
  end

  defp allow_boot(host) do
    host
    |> to_charlist()
    |> :inet.parse_ipv4_address()
    |> then(fn {:ok, ipv4} -> ipv4 end)
    |> :erl_boot_server.add_slave()
  end

  defp load_paths(node) do
    call(node, :code, :add_paths, [:code.get_path()])
  end

  def reload_paths(node) do
    call(node, :code, :del_paths, [:code.get_path()])
    load_paths(node)
  end

  def central_node_ip() do
    # alternative using interface
    :inet.getifaddrs()
    |> elem(1)
    |> Enum.find(fn {name, _} -> name == ~c"incusbr0" end)
    |> elem(1)
    |> Keyword.get(:addr)

    # node()
    # |> to_string
    # |> String.split("@")
    # |> Enum.at(1)
    # |> to_charlist
  end

  def setup_erl(instance) do
    {_, 0} =
      System.shell(
        ~s{incus exec #{instance} --  bash -i -c "which erl || nix --extra-experimental-features 'flakes nix-command' profile install nixpkgs#erlang"}
      )

    # TODO, gcroot this?
    {erl_path, 0} =
      System.shell(~s{incus exec #{instance} --  bash -i -c 'readlink -f $(which erl)'})

    Nix.Store.realize(erl_path)
  end
end
