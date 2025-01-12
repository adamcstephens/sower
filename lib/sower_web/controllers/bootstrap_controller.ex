defmodule SowerWeb.BootstrapController do
  use SowerWeb, :controller

  action_fallback SowerWeb.BootstrapFallbackController

  def client_script(conn, _params) do
    conn
    |> text(render_script())
  end

  defp render_script() do
    """
    #!/usr/bin/env nix-shell
    #! nix-shell -i bash -p curl

    set -e

    arch=$(uname -m)
    os=$(uname -s | tr '[:upper:]' '[:lower:]')

    if [[ "$os" == "darwin" && "$arch" == "arm64" ]]; then
    arch="aarch64"
    fi

    system="$arch-$os"
    echo ":: Found system $system"

    export SOWER_ENDPOINT="<%= sower_url %>"

    echo ":: Downloading sower client"
    if ! curl --fail --output /tmp/sower --silent $SOWER_ENDPOINT/client/bin/$system; then
      echo ":: Failed to download"
      cat /tmp/sower
      rm /tmp/sower
      exit 1
    fi

    echo ":: Running sower client"
    chmod +x /tmp/sower
    /tmp/sower $@

    rm -f /tmp/sower

    echo ":: Done!"
    """
    |> EEx.eval_string(sower_url: Application.get_env(:sower, :public_url))
  end

  def client_bin(conn, %{"system" => system}) do
    clients = Application.get_env(:sower, :clients)

    # don't trust input when it comes to the local filesystem
    if system in (clients |> Keyword.keys() |> Enum.map(&Atom.to_string/1)) do
      local_path =
        Kernel.get_in(clients, [String.to_existing_atom(system), :path]) <> "/bin/sower"

      if File.exists?(local_path) do
        conn
        |> send_download({:file, local_path},
          filename: "sower",
          content_type: "application/octet-stream"
        )
      else
        conn
        |> put_status(:not_found)
        |> text("Not found")
        |> halt()
      end
    else
      conn
      |> put_status(:not_found)
      |> text("Not found")
      |> halt()
    end
  end
end
