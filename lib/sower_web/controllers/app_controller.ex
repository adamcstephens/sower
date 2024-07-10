defmodule SowerWeb.AppController do
  use SowerWeb, :controller

  action_fallback SowerWeb.AppFallbackController

  def client_script(conn, _params) do
    with {:ok, nix_caches} <- Application.fetch_env(:sower, :nix_caches),
         {:ok, sower_url} <- Application.fetch_env(:sower, :public_url) do
      case Application.fetch_env(:sower, :clients) do
        {:ok, clients} ->
          conn
          |> assign(:clients, clients)
          |> assign(:nix_caches, nix_caches)
          |> assign(:sower_url, sower_url)
          |> put_root_layout(false)
          |> render(:client_script, layout: false)

        :error ->
          conn
          |> Plug.Conn.put_status(404)
          |> put_root_layout(false)
          |> Plug.Conn.halt()
          |> html("echo 'Error: client paths not configured on sower server'; exit 1")
      end
    end
  end

  # TODO: this should really be somewhere related to an api
  def config(conn, _params) do
    with {:ok, nix_caches} <- Application.fetch_env(:sower, :nix_caches) do
      # convert back to list of maps
      nix_caches = nix_caches |> Enum.map(&(&1 |> Enum.into(%{})))

      conn
      |> put_root_layout(false)
      |> json(%{nix_caches: nix_caches})
    end
  end
end
