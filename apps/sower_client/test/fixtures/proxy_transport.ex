defmodule SowerClient.ProxyTransportFixture do
  import ExUnit.Assertions

  def tls_config do
    :public_key.pkix_test_data(%{
      root: [key: {:rsa, 2048, 65537}, digest: :sha256],
      intermediates: [],
      peer: [
        key: {:rsa, 2048, 65537},
        digest: :sha256,
        extensions: [{:Extension, {2, 5, 29, 17}, false, [{:dNSName, ~c"localhost"}]}]
      ]
    })
  end

  def trust(config), do: [verify: :verify_peer, cacerts: Keyword.fetch!(config, :cacerts)]

  def listen(scheme, tls, handler, options \\ []) do
    transport = if scheme == :http, do: :gen_tcp, else: :ssl
    ip = Keyword.get(options, :ip, {127, 0, 0, 1})
    family = if tuple_size(ip) == 8, do: :inet6, else: :inet
    opts = [:binary, family, active: false, reuseaddr: true, ip: ip]
    opts = if transport == :ssl, do: opts ++ tls, else: opts
    {:ok, listener} = transport.listen(Keyword.get(options, :port, 0), opts)

    {:ok, {_, port}} =
      if transport == :ssl, do: :ssl.sockname(listener), else: :inet.sockname(listener)

    pid = spawn_link(fn -> accept(listener, transport, handler) end)

    ExUnit.Callbacks.on_exit(fn ->
      Process.exit(pid, :kill)
      transport.close(listener)
    end)

    port
  end

  defp accept(listener, transport, handler) do
    result =
      case transport do
        :gen_tcp -> :gen_tcp.accept(listener)
        :ssl -> :ssl.transport_accept(listener)
      end

    case result do
      {:ok, socket} ->
        pid =
          spawn_link(fn ->
            receive do
              :ready -> serve(transport, socket, handler)
            end
          end)

        :ok = transport.controlling_process(socket, pid)
        send(pid, :ready)
        accept(listener, transport, handler)

      {:error, :closed} ->
        :ok
    end
  end

  defp serve(:ssl, socket, handler) do
    case :ssl.handshake(socket) do
      {:ok, socket} ->
        handler.(:ssl, socket)
        :ssl.close(socket)

      {:error, _reason} ->
        :ssl.close(socket)
    end
  end

  defp serve(:gen_tcp, socket, handler) do
    handler.(:gen_tcp, socket)
    :gen_tcp.close(socket)
  end

  def proxy(scheme, tls, owner, expected_auth, options \\ []) do
    listen(
      scheme,
      tls,
      fn transport, socket ->
        {request, headers} = read_headers(transport, socket)
        send(owner, {:proxy_request, request, headers})

        if headers["proxy-authorization"] == expected_auth do
          [method, target, version] = String.split(request, " ")

          {host, port, forwarded} =
            if method == "CONNECT" do
              uri = URI.parse("http://" <> target)
              {uri.host, uri.port, nil}
            else
              uri = URI.parse(target)
              path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")
              headers = Map.delete(headers, "proxy-authorization")
              lines = Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end)
              {uri.host, uri.port, [[method, " ", path, " ", version, "\r\n"], lines, "\r\n"]}
            end

          {:ok, upstream} =
            :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 5_000)

          if forwarded do
            :ok = :gen_tcp.send(upstream, forwarded)
          else
            :ok = transport.send(socket, "HTTP/1.1 200 Connection Established\r\n\r\n")
          end

          :ok = set_active(transport, socket)
          :ok = :inet.setopts(upstream, active: true)
          relay(transport, socket, upstream)
          :gen_tcp.close(upstream)
        else
          transport.send(
            socket,
            "HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\n\r\n"
          )
        end
      end,
      options
    )
  end

  defp relay(transport, socket, upstream) do
    receive do
      {tag, ^socket, bytes} when tag in [:tcp, :ssl] ->
        case :gen_tcp.send(upstream, bytes) do
          :ok -> relay(transport, socket, upstream)
          {:error, :closed} -> :ok
          {:error, reason} -> flunk("proxy upstream send failed: #{inspect(reason)}")
        end

      {:tcp, ^upstream, bytes} ->
        case transport.send(socket, bytes) do
          :ok -> relay(transport, socket, upstream)
          {:error, :closed} -> :ok
          {:error, reason} -> flunk("proxy downstream send failed: #{inspect(reason)}")
        end

      {tag, _} when tag in [:tcp_closed, :ssl_closed] ->
        :ok

      {tag, _, reason} when tag in [:tcp_error, :ssl_error] ->
        flunk("proxy socket failed: #{inspect(reason)}")
    after
      5_000 -> flunk("proxy relay timed out")
    end
  end

  defp set_active(:ssl, socket), do: :ssl.setopts(socket, active: true)
  defp set_active(:gen_tcp, socket), do: :inet.setopts(socket, active: true)

  def read_headers(transport, socket, bytes \\ "") do
    if String.ends_with?(bytes, "\r\n\r\n") do
      [request | lines] = String.split(bytes, "\r\n", trim: true)

      headers =
        Map.new(lines, fn line ->
          [name, value] = String.split(line, ":", parts: 2)
          {String.downcase(name), String.trim(value)}
        end)

      {request, headers}
    else
      {:ok, byte} = transport.recv(socket, 1, 5_000)
      read_headers(transport, socket, bytes <> byte)
    end
  end

  def websocket(scheme, tls, owner) do
    listen(scheme, tls, fn transport, socket ->
      {request, headers} = read_headers(transport, socket)
      send(owner, {:origin_request, request, headers})

      accept =
        :crypto.hash(:sha, headers["sec-websocket-key"] <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
        |> Base.encode64()

      :ok =
        transport.send(
          socket,
          "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
        )

      {:ok, <<0x81, 1::1, length::7>>} = transport.recv(socket, 2, 5_000)
      {:ok, mask} = transport.recv(socket, 4, 5_000)
      {:ok, payload} = transport.recv(socket, length, 5_000)

      decoded =
        payload
        |> :binary.bin_to_list()
        |> Enum.with_index()
        |> Enum.map(fn {byte, index} -> Bitwise.bxor(byte, :binary.at(mask, rem(index, 4))) end)
        |> :binary.list_to_bin()

      send(owner, {:origin_frame, decoded})
      :ok = transport.send(socket, <<0x81, byte_size(decoded), decoded::binary>>)
      transport.recv(socket, 0, 5_000)
    end)
  end
end
