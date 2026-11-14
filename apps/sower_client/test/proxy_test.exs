defmodule SowerClient.ProxyTest do
  use ExUnit.Case, async: true

  alias SowerClient.Proxy

  test "direct routing removes stale proxy settings and preserves transport options" do
    options = [
      protocols: [:http1],
      proxy: {:http, "old", 80, []},
      proxy_headers: [{"proxy-authorization", "secret"}]
    ]

    assert {:ok, [protocols: [:http1]]} =
             Proxy.mint_options("https://sower.example", options, %{})
  end

  test "HTTP and WebSocket use independent destination scheme variables" do
    env = %{"http_proxy" => "http://plain.proxy", "https_proxy" => "https://secure.proxy"}

    for scheme <- ["http", "ws"] do
      assert {:ok, options} = Proxy.mint_options("#{scheme}://sower.example", [], env)
      assert options[:proxy] == {:http, "plain.proxy", 80, []}
    end

    for scheme <- ["https", "wss"] do
      assert {:ok, options} = Proxy.mint_options("#{scheme}://sower.example", [], env)
      assert options[:proxy] == {:https, "secure.proxy", 443, []}

      assert {:ok, []} =
               Proxy.mint_options("#{scheme}://sower.example", [], Map.delete(env, "https_proxy"))
    end
  end

  test "uppercase overrides lowercase including an explicitly empty value" do
    env = %{"HTTP_PROXY" => "http://upper.proxy", "http_proxy" => "http://lower.proxy"}
    assert {:ok, options} = Proxy.mint_options("http://sower.example", [], env)
    assert options[:proxy] == {:http, "upper.proxy", 80, []}

    assert {:ok, []} =
             Proxy.mint_options("http://sower.example", [], Map.put(env, "HTTP_PROXY", ""))
  end

  test "userinfo uses percent decoding, preserves plus and splits at the first colon" do
    env = %{"HTTPS_PROXY" => "https://user%3Aname+p:pa%40ss:word+@proxy.example"}
    assert {:ok, options} = Proxy.mint_options("https://sower.example", [], env)
    assert options[:proxy] == {:https, "proxy.example", 443, []}

    assert options[:proxy_headers] == [
             {"proxy-authorization", "Basic " <> Base.encode64("user:name+p:pa@ss:word+")}
           ]
  end

  test "IPv6 proxy authorities and default ports are parsed without userinfo in endpoint" do
    env = %{"HTTP_PROXY" => "https://user:pass@[::1]"}
    assert {:ok, options} = Proxy.mint_options("http://sower.example", [], env)
    assert options[:proxy] == {:https, "::1", 443, [transport_opts: [inet6: true]]}
  end

  test "HTTPS proxy shares trust roots but never origin TLS identity or verification overrides" do
    transport = [
      cacerts: [:trusted_root],
      cert: :origin_certificate,
      key: :origin_key,
      server_name_indication: ~c"origin.example",
      verify: :verify_none,
      verify_fun: {fn _, _, state -> {:valid, state} end, nil}
    ]

    assert {:ok, options} =
             Proxy.mint_options("https://origin.example", [transport_opts: transport], %{
               "HTTPS_PROXY" => "https://proxy.example"
             })

    assert options[:transport_opts] == transport

    assert options[:proxy] ==
             {:https, "proxy.example", 443, [transport_opts: [cacerts: [:trusted_root]]]}
  end

  test "IPv6 bypass compares equivalent address representations" do
    env = %{"HTTP_PROXY" => "http://proxy.example", "NO_PROXY" => "::1"}
    assert {:ok, []} = Proxy.mint_options("http://[0:0:0:0:0:0:0:1]", [], env)
    assert {:ok, options} = Proxy.mint_options("http://[0:0:0:0:0:0:0:2]", [], env)
    assert options[:proxy] != nil
  end

  test "bypass supports exact hosts, suffix label boundaries and IP literals" do
    env = %{
      "HTTP_PROXY" => "http://proxy.example",
      "NO_PROXY" => " local, .Example.COM, 127.0.0.1, [::1] "
    }

    for host <- ["local", "example.com", "sub.example.com", "127.0.0.1", "[::1]"] do
      assert {:ok, []} = Proxy.mint_options("http://#{host}", [], env)
    end

    for host <- ["notexample.com", "example.com.evil", "127.0.0.2", "[::2]"] do
      assert {:ok, options} = Proxy.mint_options("http://#{host}", [], env)
      assert options[:proxy] != nil
    end
  end

  test "IP literals are not treated as domain suffixes" do
    env = %{"HTTP_PROXY" => "http://proxy.example", "NO_PROXY" => "0.0.1"}
    assert {:ok, options} = Proxy.mint_options("http://127.0.0.1", [], env)
    assert options[:proxy] != nil
  end

  test "uppercase empty bypass overrides lowercase wildcard" do
    env = %{"HTTP_PROXY" => "http://proxy.example", "NO_PROXY" => "", "no_proxy" => "*"}
    assert {:ok, options} = Proxy.mint_options("http://sower.example", [], env)
    assert options[:proxy] != nil
    assert {:ok, []} = Proxy.mint_options("http://sower.example", [], Map.delete(env, "NO_PROXY"))
  end

  test "invalid proxy configuration returns a credential-free error rather than direct routing" do
    for proxy <- [
          "socks5://user:secret@proxy.example",
          "https://user:secret@proxy.example:wrong",
          "http://"
        ] do
      assert {:error, error} =
               Proxy.mint_options("http://sower.example", [], %{"HTTP_PROXY" => proxy})

      assert Exception.message(error) == "invalid HTTP proxy configuration"
      refute inspect(error) =~ "secret"
      refute inspect(error) =~ Base.encode64("user:secret")
    end
  end
end
