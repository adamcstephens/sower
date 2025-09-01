defmodule SowerWeb.BootstrapController do
  use SowerWeb, :controller

  require Logger

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

    tmpfile=$(mktemp)

    echo ":: Downloading sower client"
    if ! curl --fail --output "${tmpfile}" --silent $SOWER_ENDPOINT/client/bin/$system; then
      echo ":: Failed to download"
      cat "${tmpfile}"
      rm -f "${tmpfile}"
      exit 1
    fi

    echo ":: Running sower client"
    chmod +x "${tmpfile}"
    eval "${tmpfile}" $@

    rm -f "${tmpfile}"

    echo ":: Done!"
    """
    |> EEx.eval_string(sower_url: Application.get_env(:sower, :public_url))
  end

  def client_bin(conn, %{"system" => system}) do
    clients = Application.get_env(:sower, :clients)

    system =
      try do
        String.to_existing_atom(system)
      rescue
        _ ->
          :not_found
      end

    if system in (clients |> Keyword.keys()) do
      local_path =
        Kernel.get_in(clients, [system, :path]) <> "/bin/sower"

      if File.exists?(local_path) do
        Logger.debug(msg: "Sending download file", local_path: local_path, system: system)

        conn
        |> send_download({:file, local_path},
          filename: "sower",
          content_type: "application/octet-stream"
        )
      else
        Logger.error(msg: "Download file not found", local_path: local_path, system: system)

        conn
        |> put_status(:not_found)
        |> text("Not found")
        |> halt()
      end
    else
      Logger.error(msg: "Unknown system requested for download", system: system)

      conn
      |> put_status(:not_found)
      |> text("Not found")
      |> halt()
    end
  end
end
