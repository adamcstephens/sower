Code.require_file("../../../../sower_client/test/fixtures/proxy_transport.ex", __DIR__)

defmodule Garden.Socket.ProxyTest do
  use ExUnit.Case, async: false

  alias SowerClient.ProxyTransportFixture, as: Fixture

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
    keys = @proxy_keys ++ ["SOWER_ENDPOINT", "SOWER_ACCESS_TOKEN", "SOWER_ACCESS_TOKEN_FILE"]
    environment = Map.new(keys, &{&1, System.get_env(&1)})
    Enum.each(keys, &System.delete_env/1)
    config = Garden.Config.get()
    socket_config = Application.get_env(:garden, Garden.Socket, [])
    storage = Garden.Storage.read()
    api_config = Application.get_all_env(SowerClient.ApiClient)

    on_exit(fn ->
      Enum.each(environment, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      Application.put_env(:garden, :config, config)

      Application.put_env(:garden, Garden.Socket, socket_config)

      Enum.each(Application.get_all_env(SowerClient.ApiClient), fn {key, _} ->
        Application.delete_env(SowerClient.ApiClient, key)
      end)

      Enum.each(api_config, fn {key, value} ->
        Application.put_env(SowerClient.ApiClient, key, value)
      end)

      Garden.Storage.write(storage)
    end)

    Garden.Storage.write(%Garden.Storage{})
    owner = self()
    origin = Fixture.listen(:http, [], &serve(&1, &2, owner))
    proxy = Fixture.proxy(:http, [], owner, "Basic " <> Base.encode64("proxy-user:proxy-secret"))
    System.put_env("HTTP_PROXY", "http://proxy-user:proxy-secret@localhost:#{proxy}")

    overrides = %{
      endpoint: "http://localhost:#{origin}",
      access_token: "bootstrap-secret",
      state_directory: config.state_directory,
      name: "proxy-garden",
      subscriptions: [],
      timezone: "Etc/UTC"
    }

    Garden.Config.load(overrides, skip_config_file: true)
    configure_socket(reconnect_after_msec: [60_000])

    %{proxy: proxy, overrides: overrides}
  end

  test "explicit config load refreshes proxy credentials while environment changes alone do not",
       %{overrides: overrides} do
    options = [protocols: [:http2, :http1], transport_opts: [timeout: 1_234]]
    configure_socket(mint_opts: options)
    System.put_env("HTTP_PROXY", "http://first:secret@proxy-one.test:8080")
    Garden.Config.load(overrides, skip_config_file: true)
    first = Application.fetch_env!(:garden, Garden.Socket)
    assert first[:mint_opts][:proxy] == {:http, "proxy-one.test", 8080, []}

    assert first[:mint_opts][:proxy_headers] == [
             {"proxy-authorization", "Basic " <> Base.encode64("first:secret")}
           ]

    assert first[:mint_opts][:protocols] == [:http2, :http1]
    assert first[:mint_opts][:transport_opts] == [timeout: 1_234]

    System.put_env("HTTP_PROXY", "http://proxy-two.test:8081")
    assert Application.fetch_env!(:garden, Garden.Socket) == first
    Garden.Config.load(overrides, skip_config_file: true)
    second = Application.fetch_env!(:garden, Garden.Socket)
    assert second[:mint_opts][:proxy] == {:http, "proxy-two.test", 8081, []}
    assert second[:mint_opts][:proxy_headers] == []

    System.put_env("NO_PROXY", "localhost")
    assert Application.fetch_env!(:garden, Garden.Socket) == second
    Garden.Config.load(overrides, skip_config_file: true)
    assert Application.fetch_env!(:garden, Garden.Socket)[:mint_opts] == options
  end

  test "explicit config load resolves the new endpoint scheme", %{overrides: overrides} do
    System.put_env("HTTP_PROXY", "http://plain.test:8080")
    System.put_env("HTTPS_PROXY", "http://secure:secret@tls.test:8081")
    Garden.Config.load(overrides, skip_config_file: true)

    assert Application.fetch_env!(:garden, Garden.Socket)[:mint_opts][:proxy] ==
             {:http, "plain.test", 8080, []}

    Garden.Config.load(%{overrides | endpoint: "https://secure-origin.test"},
      skip_config_file: true
    )

    secure = Application.fetch_env!(:garden, Garden.Socket)
    assert secure[:uri] == URI.parse("wss://secure-origin.test/garden/websocket")
    assert secure[:mint_opts][:proxy] == {:http, "tls.test", 8081, []}

    assert secure[:mint_opts][:proxy_headers] == [
             {"proxy-authorization", "Basic " <> Base.encode64("secure:secret")}
           ]

    assert secure[:mint_opts][:protocols] == [:http1]
  end

  test "invalid proxy config load raises safely without replacing stored socket config", %{
    overrides: overrides
  } do
    stored = Application.fetch_env!(:garden, Garden.Socket)
    System.put_env("HTTP_PROXY", "ftp://private-user:private-password@proxy.test:8080")

    error =
      assert_raise ArgumentError, fn ->
        Garden.Config.load(overrides, skip_config_file: true)
      end

    assert Exception.message(error) =~ "proxy"
    refute inspect(error) =~ "private-user"
    refute inspect(error) =~ "private-password"
    assert Application.fetch_env!(:garden, Garden.Socket) == stored
  end

  test "boot config load stores the generated URI, backoff and default HTTP1 options", %{
    overrides: overrides
  } do
    Application.put_env(:garden, Garden.Socket,
      uri: URI.parse("ws://stale-origin.test/garden/websocket"),
      reconnect_after_msec: [42]
    )

    Garden.Config.load(%{overrides | endpoint: "https://boot-origin.test"},
      skip_config_file: true
    )

    stored = Application.fetch_env!(:garden, Garden.Socket)
    assert stored[:uri] == URI.parse("wss://boot-origin.test/garden/websocket")
    assert stored[:reconnect_after_msec] == Garden.Socket.Lifecycle.default_backoff()
    assert stored[:mint_opts] == [protocols: [:http1]]
  end

  test "test runtime enables the Req proxy plugin for ordinary requests" do
    assert SowerClient.Proxy in Application.fetch_env!(:req, :default_options)[:plugins]
  end

  test "registers, exchanges and refreshes tokens, joins and reconnects through the proxy" do
    configure_socket(reconnect_after_msec: [20])
    start_supervised!(Garden.Scheduler)
    socket = start_supervised!({Garden.Socket, []})

    assert_receive {:http_request, "/api/v1/gardens/register", registration_headers,
                    registration},
                   5_000

    assert registration_headers["authorization"] == "Bearer bootstrap-secret"
    refute Map.has_key?(registration_headers, "proxy-authorization")
    assert registration["name"] == "proxy-garden"
    assert registration["public_key"] =~ "PUBLIC KEY"
    assert_receive {:http_request, "/api/oauth/token", token_headers, _}, 5_000
    refute Map.has_key?(token_headers, "proxy-authorization")
    assert_receive {:joined, "garden:proxy-garden", transport, connection}, 5_000
    assert_receive :subscriptions_synced, 5_000
    :sys.get_state(socket)
    identity = Garden.Storage.read()
    assert identity.garden_sid == "proxy-garden"
    assert identity.oauth_credentials.client_id == "proxy-client"

    send(socket, :reauthenticate)
    assert_receive {:http_request, "/api/oauth/token", _, _}, 5_000
    :sys.get_state(socket)
    refreshed = Garden.Storage.read()
    assert refreshed.oauth_credentials.access_token != identity.oauth_credentials.access_token
    assert refreshed.private_key_pem == identity.private_key_pem

    boot_socket_config = Application.fetch_env!(:garden, Garden.Socket)
    System.put_env("HTTP_PROXY", "http://wrong:password@localhost:1")
    transport.close(connection)
    assert_receive {:websocket_closed, _}, 5_000
    assert_receive {:joined, "garden:proxy-garden", _, _}, 5_000
    assert Garden.Storage.read().garden_sid == identity.garden_sid
    assert_receive :subscriptions_synced, 5_000
    :sys.get_state(socket)
    assert Application.fetch_env!(:garden, Garden.Socket) == boot_socket_config
    refute_receive {:http_request, "/api/v1/gardens/register", _, _}, 100
    assert_receive {:proxy_request, "POST http://" <> _, headers}
    assert headers["proxy-authorization"] == "Basic " <> Base.encode64("proxy-user:proxy-secret")
    assert_receive {:proxy_request, "POST http://" <> _, _}
    assert_receive {:proxy_request, "POST http://" <> _, _}
    assert_receive {:proxy_request, "GET http://" <> _, _}
    assert_receive {:proxy_request, "GET http://" <> _, _}
  end

  for failure <- [:rejection, :outage] do
    test "preserves cached identity during proxy #{failure} without registering again", %{
      proxy: proxy,
      overrides: overrides
    } do
      {private_key, _} = Garden.Auth.generate_keypair()

      identity = %Garden.Storage{
        garden_sid: "cached-garden",
        private_key_pem: private_key,
        oauth_credentials: %{
          client_id: "cached-client",
          access_token: "expired-token",
          token_issued_at: 0,
          expires_in: 1
        }
      }

      Garden.Storage.write(identity)

      case unquote(failure) do
        :rejection ->
          System.put_env("HTTP_PROXY", "http://wrong:password@localhost:#{proxy}")

        :outage ->
          {:ok, listener} = :gen_tcp.listen(0, [])
          {:ok, {_, unused_port}} = :inet.sockname(listener)
          :gen_tcp.close(listener)
          System.put_env("HTTP_PROXY", "http://localhost:#{unused_port}")
      end

      Garden.Config.load(overrides, skip_config_file: true)
      configure_socket(reconnect_after_msec: [60_000])

      socket = start_supervised!({Garden.Socket, []})
      assert Garden.Storage.read() == identity
      send(socket, :attempt_reconnect)
      :sys.get_state(socket)
      assert Garden.Storage.read() == identity
      refute_receive {:http_request, _, _, _}, 100
      refute_receive {:joined, _, _, _}, 100
    end
  end

  defp configure_socket(options) do
    config = Application.get_env(:garden, Garden.Socket, [])
    Application.put_env(:garden, Garden.Socket, Keyword.merge(config, options))
  end

  defp serve(transport, socket, owner) do
    {request, headers} = Fixture.read_headers(transport, socket)
    [_, path, _] = String.split(request, " ")
    refute Map.has_key?(headers, "proxy-authorization")

    if headers["upgrade"] == "websocket" do
      assert headers["x-auth-token"] =~ "boruta:token-"

      accept =
        :crypto.hash(:sha, headers["sec-websocket-key"] <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
        |> Base.encode64()

      transport.send(
        socket,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
      )

      frames(transport, socket, owner)
    else
      length = String.to_integer(headers["content-length"])
      {:ok, bytes} = transport.recv(socket, length, 5_000)

      body =
        if String.contains?(headers["content-type"], "json"),
          do: Jason.decode!(bytes),
          else: URI.decode_query(bytes)

      send(owner, {:http_request, path, headers, body})

      {status, response} =
        case path do
          "/api/v1/gardens/register" ->
            {201, %{sid: "proxy-garden", oauth_credentials: %{client_id: "proxy-client"}}}

          "/api/oauth/token" ->
            {200,
             %{
               access_token: "token-#{System.unique_integer([:positive])}",
               expires_in: 3600,
               token_type: "bearer"
             }}
        end

      json = Jason.encode!(response)

      transport.send(
        socket,
        "HTTP/1.1 #{status} OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(json)}\r\nConnection: close\r\n\r\n#{json}"
      )
    end
  end

  defp frames(transport, socket, owner) do
    case transport.recv(socket, 2, 10_000) do
      {:ok, <<0x81, 1::1, size::7>>} ->
        length =
          if size == 126 do
            {:ok, <<length::16>>} = transport.recv(socket, 2, 5_000)
            length
          else
            size
          end

        {:ok, mask} = transport.recv(socket, 4, 5_000)
        {:ok, payload} = transport.recv(socket, length, 5_000)

        decoded =
          payload
          |> :binary.bin_to_list()
          |> Enum.with_index()
          |> Enum.map(fn {byte, index} -> Bitwise.bxor(byte, :binary.at(mask, rem(index, 4))) end)
          |> :binary.list_to_bin()

        [join_ref, ref, topic, event, _] = Jason.decode!(decoded)

        response =
          case event do
            "phx_join" -> %{"conn_sid" => "connection"}
            "subscriptions:sync" -> %{"subscriptions" => []}
            _ -> %{}
          end

        reply =
          Jason.encode!([join_ref, ref, topic, "phx_reply", %{status: "ok", response: response}])

        :ok = transport.send(socket, [<<0x81, byte_size(reply)>>, reply])
        if event == "phx_join", do: send(owner, {:joined, topic, transport, socket})
        if event == "subscriptions:sync", do: send(owner, :subscriptions_synced)
        frames(transport, socket, owner)

      {:error, :closed} ->
        send(owner, {:websocket_closed, socket})

      {:ok, <<0x88, _>>} ->
        :ok
    end
  end
end
