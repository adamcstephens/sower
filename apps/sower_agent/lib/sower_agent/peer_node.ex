defmodule SowerAgent.PeerNode do
  require Logger
  use TypedStruct

  typedstruct do
    field :name, String.t()
    field :pid, String.t()
  end

  def start(instance) do
    instance_ip = instance_ip(instance)

    allow_boot(instance_ip)

    # {:ok, slave} = :slave.start(to_charlist(host), :slave, inet_loader_args())
    {_, peer_pid, peer_name} =
      :peer.start_link(%{
        exec: exec(instance),
        connection: :standard_io,
        name: to_charlist(instance),
        host: to_charlist(instance_ip),
        args:
          Enum.map(
            [
              "-hosts",
              central_node_ip(),
              "-setcookie",
              "#{:erlang.get_cookie()}",
              "-loader",
              "inet"
            ],
            &to_charlist/1
          )
      })

    node = %__MODULE__{pid: peer_pid, name: peer_name}

    load_paths(node)

    node
  end

  def start_agent(%__MODULE__{} = node) do
    set_config(node)

    SowerAgent.PeerNode.call(node, Application, :ensure_all_started, [:sower_agent])
  end

  def stop(%__MODULE__{} = node) do
    :peer.stop(node.pid)
  end

  def get_env(%__MODULE__{} = node, name) do
    call(node, Application, :get_env, [
      :sower_agent,
      name
    ])
  end

  def put_env(%__MODULE__{} = node, name, value) do
    call(node, Application, :put_env, [
      :sower_agent,
      name,
      value
    ])
  end

  def set_config(%__MODULE__{} = node) do
    Logger.debug(msg: "Setting configuration")

    put_env(
      node,
      :config,
      Application.get_env(:sower_agent, :config)
    )

    storage_dir = "/tmp/#{node.name}"

    SowerAgent.PeerNode.call(node, File, :mkdir_p, [storage_dir])

    put_env(
      node,
      SowerAgent.Storage,
      file: "#{storage_dir}/storage.etf"
    )

    put_env(
      node,
      SowerAgent.SocketClient,
      uri: "ws://#{central_node_ip()}:7150/agent/websocket",
      reconnect_after_msec: [200, 500, 1000, 2000]
    )
  end

  def call(%__MODULE__{} = node, module, method, args) do
    :rpc.block_call(node.name, module, method, args)
  end

  def exec(instance) do
    {:os.find_executable(~c"incus"),
     Enum.map(
       [
         "exec",
         "--",
         instance,
         "/root/.nix-profile/bin/erl"
       ],
       &to_charlist/1
     )}
  end

  # defp inet_loader_args do
  #   "-loader inet -hosts #{central_node_ip()} -setcookie #{:erlang.get_cookie()}" |> to_charlist
  # end
  #
  def instance_ip(instance) do
    System.shell("incus list -f json #{instance}")
    |> then(fn {result, 0} -> result |> Jason.decode!() end)
    |> List.first()
    |> get_in(["state", "network", "eth0", "addresses"])
    |> Enum.find(fn a -> a["family"] == "inet" end)
    |> Map.get("address")
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

  def central_node_ip() do
    node()
    |> to_string
    |> String.split("@")
    |> Enum.at(1)
    |> to_charlist
  end
end

# {_, peer, peer_name} = :peer.start_link(%{exec: {:os.find_executable(~c"incus"), [~c"exec", ~c"--", ~c"stirring-grubworm", ~c"/root/.nix-profile/bin/erl"]}, connection: :standard_io, name: ~c"stirring-grubworm", host: ~c"10.143.96.58", args: [~c"-hosts", ~c"10.143.96.1", ~c"-setcookie", ~c"#{:erlang.get_cookie()}", ~c"-loader", ~c"inet"]})

# ipaddr = :inet.getifaddrs |> elem(1) |> Enum.find(fn {name, _} -> name == ~c"incusbr0" end) |> elem(1) |> Keyword.get(:addr
