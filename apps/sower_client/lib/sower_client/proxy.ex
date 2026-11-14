defmodule SowerClient.Proxy do
  @moduledoc """
  Routes outbound Req and Mint connections using the process proxy environment.
  Client releases register this Req plugin through runtime application defaults;
  garden configuration uses the same resolver for Mint connection options.

  HTTP and WebSocket destinations use HTTP_PROXY/http_proxy; TLS destinations use
  HTTPS_PROXY/https_proxy. Uppercase variables take precedence, even when empty.
  NO_PROXY/no_proxy accepts comma-separated hosts, domain suffixes with label
  boundaries, IP literals, and `*`. Credentials are decoded only into proxy-hop
  headers. Req routing is evaluated again for each redirected destination.
  Unix-socket requests retain their local transport and bypass proxy routing.
  Explicit CA trust roots apply to both TLS hops; origin client certificates and
  verification overrides are never copied to the proxy.
  """

  def attach(%Req.Request{} = request) do
    Req.Request.append_request_steps(request, sower_proxy: &configure_request/1)
  end

  def mint_options(url, options \\ [], env \\ nil) do
    uri = URI.parse(to_string(url))
    options = Keyword.drop(options, [:proxy, :proxy_headers])
    variable = if uri.scheme in ["https", "wss"], do: "HTTPS_PROXY", else: "HTTP_PROXY"
    proxy = env_value(env, variable)

    if proxy in [nil, ""] or bypass?(uri.host, env_value(env, "NO_PROXY")) do
      {:ok, options}
    else
      case URI.new(proxy) do
        {:ok, %URI{scheme: scheme, host: host, port: port} = proxy_uri}
        when scheme in ["http", "https"] and is_binary(host) and host != "" and
               port in 1..65535 ->
          scheme = if scheme == "https", do: :https, else: :http

          trust =
            options |> Keyword.get(:transport_opts, []) |> Keyword.take([:cacerts, :cacertfile])

          proxy_options =
            if scheme == :https and trust != [], do: [transport_opts: trust], else: []

          proxy_options =
            if String.contains?(host, ":") do
              Keyword.update(proxy_options, :transport_opts, [inet6: true], fn opts ->
                Keyword.put(opts, :inet6, true)
              end)
            else
              proxy_options
            end

          {:ok,
           options ++
             [
               proxy: {scheme, host, port, proxy_options},
               proxy_headers: authorization(proxy_uri.userinfo)
             ]}

        _ ->
          {:error, ArgumentError.exception("invalid HTTP proxy configuration")}
      end
    end
  end

  defp configure_request(%Req.Request{options: %{unix_socket: socket}} = request)
       when is_binary(socket) do
    Req.Request.delete_header(request, "proxy-authorization")
  end

  defp configure_request(%Req.Request{} = request) do
    options = Req.Request.get_option(request, :connect_options, [])
    request = Req.Request.delete_header(request, "proxy-authorization")

    case mint_options(request.url, options) do
      {:ok, []} -> Req.Request.delete_option(request, :connect_options)
      {:ok, options} -> Req.Request.put_option(request, :connect_options, options)
      {:error, error} -> {request, error}
    end
  end

  defp env_value(nil, name), do: System.get_env(name) || System.get_env(String.downcase(name))

  defp env_value(env, name), do: Map.get(env, name, Map.get(env, String.downcase(name)))

  defp authorization(nil), do: []

  defp authorization(userinfo) do
    [username | password] = String.split(userinfo, ":", parts: 2)
    password = List.first(password) || ""
    credentials = URI.decode(username) <> ":" <> URI.decode(password)
    [{"proxy-authorization", "Basic " <> Base.encode64(credentials)}]
  end

  defp bypass?(_host, nil), do: false

  defp bypass?(host, no_proxy) do
    host = normalize_host(host)
    address = :inet.parse_address(String.to_charlist(host))

    no_proxy
    |> String.split(",", trim: true)
    |> Enum.any?(fn entry ->
      entry = entry |> String.trim() |> normalize_host() |> String.trim_leading(".")

      case {address, :inet.parse_address(String.to_charlist(entry))} do
        {{:ok, address}, {:ok, address}} ->
          true

        {{:error, _}, {:error, _}} ->
          entry == "*" or host == entry or
            (entry != "" and String.ends_with?(host, "." <> entry))

        _ ->
          entry == "*"
      end
    end)
  end

  defp normalize_host(host) do
    host |> String.downcase() |> String.trim_leading("[") |> String.trim_trailing("]")
  end
end
