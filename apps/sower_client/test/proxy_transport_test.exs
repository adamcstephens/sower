Code.require_file("fixtures/proxy_transport.ex", __DIR__)

defmodule SowerClient.ProxyTransportTest do
  use ExUnit.Case, async: true

  alias SowerClient.ProxyTransportFixture, as: Fixture

  setup_all do
    Application.ensure_all_started(:ssl)
    {:ok, tls: Fixture.tls_config()}
  end

  for {destination, scheme} <- [{:http, :ws}, {:https, :wss}],
      proxy <- [:http, :https],
      mode <- [:active, :passive] do
    test "#{destination} WebSocket exchanges #{mode} frames through authenticated #{proxy} proxy",
         %{tls: tls} do
      destination = unquote(destination)
      proxy = unquote(proxy)
      mode = unquote(mode)
      origin_port = Fixture.websocket(destination, tls, self())
      auth = "Basic " <> Base.encode64("user:name:p@ss+word")
      proxy_port = Fixture.proxy(proxy, tls, self(), auth)

      scheme = unquote(scheme)
      env_key = if unquote(destination) == :http, do: "HTTP_PROXY", else: "HTTPS_PROXY"
      env = %{env_key => "#{proxy}://user%3Aname:p%40ss+word@localhost:#{proxy_port}"}

      assert {:ok, options} =
               SowerClient.Proxy.mint_options(
                 "#{scheme}://localhost:#{origin_port}/socket",
                 [protocols: [:http1], mode: mode, transport_opts: Fixture.trust(tls)],
                 env
               )

      assert {:ok, conn} = Mint.HTTP.connect(destination, "localhost", origin_port, options)
      assert {:ok, conn, ref} = Mint.WebSocket.upgrade(scheme, conn, "/socket", [])
      {conn, responses} = handshake(conn, [], mode)
      assert {:status, ref, 101} in responses
      {:headers, ^ref, headers} = Enum.find(responses, &match?({:headers, _, _}, &1))
      assert {:ok, conn, websocket} = Mint.WebSocket.new(conn, ref, 101, headers, mode: mode)
      assert {:ok, websocket, bytes} = Mint.WebSocket.encode(websocket, {:text, "proxy frame"})
      assert {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, bytes)
      assert {:ok, conn, [{:data, ^ref, reply}]} = receive_frame(conn, mode)
      assert {:ok, _, [{:text, "proxy frame"}]} = Mint.WebSocket.decode(websocket, reply)
      assert_receive {:proxy_request, _, %{"proxy-authorization" => ^auth}}
      assert_receive {:origin_request, "GET /socket HTTP/1.1", origin_headers}
      refute Map.has_key?(origin_headers, "proxy-authorization")
      refute Map.has_key?(origin_headers, "authorization")
      assert_receive {:origin_frame, "proxy frame"}
      Mint.HTTP.close(conn)
    end
  end

  test "routes authenticated requests through an IPv6 proxy", %{tls: tls} do
    owner = self()

    origin_port =
      Fixture.listen(:http, tls, fn transport, socket ->
        {request, headers} = Fixture.read_headers(transport, socket)
        send(owner, {:origin_request, request, headers})
        transport.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
      end)

    auth = "Basic " <> Base.encode64("user:pass")
    proxy_port = Fixture.proxy(:http, tls, self(), auth, ip: {0, 0, 0, 0, 0, 0, 0, 1})

    assert {:ok, options} =
             SowerClient.Proxy.mint_options(
               "http://localhost:#{origin_port}",
               [protocols: [:http1], mode: :passive],
               %{"HTTP_PROXY" => "http://user:pass@[::1]:#{proxy_port}"}
             )

    assert {:ok, conn} = Mint.HTTP.connect(:http, "localhost", origin_port, options)
    assert {:ok, conn, ref} = Mint.HTTP.request(conn, "GET", "/", [], nil)
    {conn, responses} = handshake(conn, [], :passive)
    assert {:status, ref, 200} in responses
    assert {:data, ref, "ok"} in responses
    assert_receive {:proxy_request, _, %{"proxy-authorization" => ^auth}}
    assert_receive {:origin_request, _, headers}
    refute Map.has_key?(headers, "proxy-authorization")
    Mint.HTTP.close(conn)
  end

  defp handshake(conn, responses, mode) do
    if Enum.any?(responses, &match?({:done, _}, &1)) do
      {conn, responses}
    else
      result =
        case mode do
          :passive ->
            Mint.HTTP.recv(conn, 0, 5_000)

          :active ->
            receive do
              {tag, _, _} = message when tag in [:tcp, :ssl] -> Mint.HTTP.stream(conn, message)
            after
              5_000 -> flunk("WebSocket handshake timed out")
            end
        end

      assert {:ok, conn, received} = result
      handshake(conn, responses ++ received, mode)
    end
  end

  defp receive_frame(conn, :passive), do: Mint.WebSocket.recv(conn, 0, 5_000)

  defp receive_frame(conn, :active) do
    receive do
      {tag, _, _} = message when tag in [:tcp, :ssl] -> Mint.WebSocket.stream(conn, message)
    after
      5_000 -> flunk("WebSocket frame timed out")
    end
  end
end
