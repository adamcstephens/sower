Code.require_file("../../../sower_client/test/fixtures/proxy_transport.ex", __DIR__)

defmodule SowerCli.BuildProxyTest do
  use ExUnit.Case, async: false

  alias SowerClient.ProxyTransportFixture, as: Fixture

  @moduletag :tmp_dir
  @proxy_keys [
    "HTTP_PROXY",
    "http_proxy",
    "HTTPS_PROXY",
    "https_proxy",
    "NO_PROXY",
    "no_proxy",
    "ALL_PROXY",
    "all_proxy"
  ]

  setup do
    environment = Map.new(@proxy_keys, &{&1, System.get_env(&1)})
    api_config = Application.get_all_env(SowerClient.ApiClient)
    Enum.each(@proxy_keys, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(environment, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      Enum.each(Application.get_all_env(SowerClient.ApiClient), fn {key, _} ->
        Application.delete_env(SowerClient.ApiClient, key)
      end)

      Enum.each(api_config, fn {key, value} ->
        Application.put_env(SowerClient.ApiClient, key, value)
      end)
    end)
  end

  test "registers built seed manifests through an authenticated proxy", %{tmp_dir: dir} do
    owner = self()

    origin =
      Fixture.listen(:http, [], fn transport, socket ->
        {request, headers} = Fixture.read_headers(transport, socket)
        {:ok, body} = transport.recv(socket, String.to_integer(headers["content-length"]), 5_000)
        seed = Jason.decode!(body)
        send(owner, {:seed_registration, request, headers, seed})
        response = Jason.encode!(Map.put(seed, "sid", "registered-seed"))

        transport.send(
          socket,
          "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(response)}\r\nConnection: close\r\n\r\n#{response}"
        )
      end)

    authorization = "Basic " <> Base.encode64("build-user:build-secret")
    proxy = Fixture.proxy(:http, [], owner, authorization)
    System.put_env("HTTP_PROXY", "http://build-user:build-secret@localhost:#{proxy}")
    Application.put_env(SowerClient.ApiClient, :uri, "http://localhost:#{origin}/api/v1")
    Application.put_env(SowerClient.ApiClient, :token, "build-api-token")

    artifact = "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-system"

    File.write!(
      Path.join(dir, "seed.json"),
      Jason.encode!(%{
        version: 1,
        name: "host",
        seed_type: "nixos",
        artifact: artifact,
        tags: %{}
      })
    )

    state = %SowerCli.Build{
      builds: [
        %Nix.Build{
          store_path: dir,
          status: :ok,
          eval: %Nix.Eval{request: %Nix.Eval.Request{attr: "nixos/host"}}
        }
      ],
      options: %{tag: []},
      flags: %{non_authoritative: false}
    }

    SowerCli.Output.init(debug: true)

    ExUnit.CaptureIO.capture_io(fn ->
      assert [{:ok, %SowerClient.Seed{sid: "registered-seed", artifact: ^artifact}}] =
               SowerCli.Build.register_seeds(state, SowerClient.ApiClient.new(), [])
    end)

    assert_receive {:proxy_request, "POST http://" <> _, proxy_headers}
    assert proxy_headers["proxy-authorization"] == authorization
    assert_receive {:seed_registration, "POST /api/v1/seeds?rename=true HTTP/1.1", headers, seed}
    assert headers["authorization"] == "Bearer build-api-token"
    refute Map.has_key?(headers, "proxy-authorization")
    assert seed["artifact"] == artifact
    assert seed["name"] == "host"
  end
end
