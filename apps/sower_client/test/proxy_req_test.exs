Code.require_file("fixtures/proxy_transport.ex", __DIR__)

defmodule SowerClient.ProxyReqTest do
  use ExUnit.Case, async: false

  alias SowerClient.ProxyTransportFixture, as: Fixture

  @variables [
    "HTTP_PROXY",
    "http_proxy",
    "HTTPS_PROXY",
    "https_proxy",
    "NO_PROXY",
    "no_proxy",
    "ALL_PROXY",
    "all_proxy"
  ]
  @credentials "user:name+p:pa@ss:word+"
  @authorization "Basic " <> Base.encode64(@credentials)

  setup_all do
    {:ok, _} = Application.ensure_all_started(:req)
    %{tls: Fixture.tls_config()}
  end

  setup do
    environment = Map.take(System.get_env(), @variables)
    Enum.each(@variables, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(@variables, &System.delete_env/1)
      System.put_env(environment)
    end)

    :ok
  end

  test "Unix-socket requests retain their Finch pool despite proxy environment" do
    path = Path.join(System.tmp_dir!(), "proxy-#{System.unique_integer([:positive])}.sock")
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, path}])

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    origin =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {line, headers} = Fixture.read_headers(:gen_tcp, socket)
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
        :gen_tcp.close(socket)
        {line, headers}
      end)

    System.put_env("HTTP_PROXY", "invalid://user:secret@proxy.test")

    assert {:ok, %Req.Response{status: 200, body: "ok"}} =
             Req.get("http://localhost/", unix_socket: path, finch: [size: 1], retry: false)

    assert {"GET / HTTP/1.1", headers} = Task.await(origin)
    refute Map.has_key?(headers, "proxy-authorization")
  end

  test "direct requests preserve an explicitly configured Finch pool", %{tls: tls} do
    port = origin(:http, tls)

    assert {:ok, %Req.Response{status: 200, body: "origin"}} =
             Req.get("http://localhost:#{port}", finch: [size: 1], retry: false)
  end

  for origin_scheme <- [:http, :https], proxy_scheme <- [:http, :https] do
    test "#{origin_scheme} origin through authenticated #{proxy_scheme} proxy", %{tls: tls} do
      origin_scheme = unquote(origin_scheme)
      proxy_scheme = unquote(proxy_scheme)
      origin = origin(origin_scheme, tls)
      proxy = Fixture.proxy(proxy_scheme, tls, self(), @authorization)
      variable = unquote(if origin_scheme == :https, do: "HTTPS_PROXY", else: "http_proxy")
      System.put_env(variable, "#{proxy_scheme}://user%3Aname+p:pa%40ss:word+@localhost:#{proxy}")

      assert {:ok, %{status: 200, body: "origin"}} =
               request("#{origin_scheme}://localhost:#{origin}", tls)

      assert_receive {:proxy_request, _, proxy_headers}
      assert proxy_headers["proxy-authorization"] == @authorization
      assert_receive {:origin_request, _, origin_headers}
      refute Map.has_key?(origin_headers, "proxy-authorization")
      assert origin_headers["authorization"] == "Bearer origin-token"
    end
  end

  test "direct mode preserves origin authorization", %{tls: tls} do
    port = origin(:http, tls)
    assert {:ok, %{status: 200}} = request("http://localhost:#{port}", tls)
    assert_receive {:origin_request, _, headers}
    assert headers["authorization"] == "Bearer origin-token"
    refute Map.has_key?(headers, "proxy-authorization")
  end

  test "redirect into bypass removes stale credentials and proxy selection", %{tls: tls} do
    destination = origin(:http, tls)
    redirect = origin(:http, tls, "http://127.0.0.1:#{destination}")
    proxy = Fixture.proxy(:http, tls, self(), @authorization)
    System.put_env("HTTP_PROXY", "http://user%3Aname+p:pa%40ss:word+@localhost:#{proxy}")
    System.put_env("NO_PROXY", "127.0.0.1")

    assert {:ok, %{status: 200}} = request("http://localhost:#{redirect}", tls)
    assert_receive {:proxy_request, _, headers}
    assert headers["proxy-authorization"] == @authorization
    assert_receive {:origin_request, _, _}
    assert_receive {:origin_request, _, final_headers}
    refute Map.has_key?(final_headers, "proxy-authorization")
    refute_receive {:proxy_request, _, _}
  end

  test "redirect from HTTP to HTTPS selects the HTTPS proxy independently", %{tls: tls} do
    destination = origin(:https, tls)
    redirect = origin(:http, tls, "https://localhost:#{destination}")
    http_proxy = Fixture.proxy(:http, tls, self(), @authorization)
    https_proxy = Fixture.proxy(:https, tls, self(), @authorization)
    System.put_env("HTTP_PROXY", "http://user%3Aname+p:pa%40ss:word+@localhost:#{http_proxy}")
    System.put_env("HTTPS_PROXY", "https://user%3Aname+p:pa%40ss:word+@localhost:#{https_proxy}")

    assert {:ok, %{status: 200}} = request("http://localhost:#{redirect}", tls)
    assert_receive {:proxy_request, "GET " <> _, _}
    assert_receive {:proxy_request, "CONNECT " <> _, _}
    assert_receive {:origin_request, _, _}
    assert_receive {:origin_request, _, headers}
    refute Map.has_key?(headers, "proxy-authorization")
  end

  test "proxy rejection does not fall back to the origin or leak credentials", %{tls: tls} do
    origin = origin(:https, tls)
    proxy = Fixture.proxy(:http, tls, self(), "different credentials")
    System.put_env("HTTPS_PROXY", "http://user%3Aname+p:pa%40ss:word+@localhost:#{proxy}")

    logs =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, error} = request("https://localhost:#{origin}", tls)
        refute inspect(error) =~ @credentials
        refute inspect(error) =~ @authorization
      end)

    refute logs =~ @credentials
    refute logs =~ @authorization
    refute_receive {:origin_request, _, _}
  end

  test "a TLS proxy requesting client authentication does not receive the origin identity", %{
    tls: tls
  } do
    owner = self()
    proxy_tls = Keyword.merge(tls, verify: :verify_peer, fail_if_no_peer_cert: false)

    proxy =
      Fixture.listen(:https, proxy_tls, fn transport, socket ->
        send(owner, {:proxy_peer_certificate, :ssl.peercert(socket)})
        Fixture.read_headers(transport, socket)

        transport.send(
          socket,
          "HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\n\r\n"
        )
      end)

    System.put_env("HTTPS_PROXY", "https://localhost:#{proxy}")
    origin_tls = Fixture.trust(tls) ++ Keyword.take(tls, [:cert, :key])

    assert {:error, _} =
             Req.new(
               url: "https://localhost:1",
               retry: false,
               connect_options: [transport_opts: origin_tls, protocols: [:http1]]
             )
             |> Req.get()

    assert_receive {:proxy_peer_certificate, {:error, :no_peercert}}
  end

  test "an untrusted proxy certificate remains a failure", %{tls: tls} do
    origin = origin(:http, tls)
    proxy = Fixture.proxy(:https, Fixture.tls_config(), self(), @authorization)
    System.put_env("HTTP_PROXY", "https://user%3Aname+p:pa%40ss:word+@localhost:#{proxy}")

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, _} = request("http://localhost:#{origin}", tls)
    end)

    refute_receive {:origin_request, _, _}
  end

  test "an untrusted origin certificate remains a failure through a trusted proxy", %{tls: tls} do
    origin = origin(:https, Fixture.tls_config())
    proxy = Fixture.proxy(:https, tls, self(), @authorization)
    System.put_env("HTTPS_PROXY", "https://user%3Aname+p:pa%40ss:word+@localhost:#{proxy}")

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, _} = request("https://localhost:#{origin}", tls)
    end)

    assert_receive {:proxy_request, "CONNECT " <> _, _}
    refute_receive {:origin_request, _, _}
  end

  defp request(url, tls) do
    Req.new(
      url: url,
      auth: {:bearer, "origin-token"},
      retry: false,
      connect_options: [transport_opts: Fixture.trust(tls), protocols: [:http1]]
    )
    |> Req.get()
  end

  defp origin(scheme, tls, redirect \\ nil) do
    owner = self()

    Fixture.listen(scheme, tls, fn transport, socket ->
      {request, headers} = Fixture.read_headers(transport, socket)
      send(owner, {:origin_request, request, headers})

      response =
        if redirect do
          "HTTP/1.1 302 Found\r\nLocation: #{redirect}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        else
          "HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\norigin"
        end

      :ok = transport.send(socket, response)
    end)
  end
end
