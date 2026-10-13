defmodule Garden.WorkStore.HTTP do
  @moduledoc false
  @behaviour Plug
  import Plug.Conn
  alias Garden.WorkStore.{Service, Narinfo}

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(conn, {service, mode}) do
    key = Enum.join(conn.path_info, "/")

    if conn.query_string != "" or conn.request_path != "/" <> key do
      send_resp(conn, 400, "invalid cache path")
    else
      case Service.context(service) do
        {:ok, store, sid, stage, limit} ->
          dispatch(conn, service, mode, store, sid, stage, limit, key)

        {:error, _} ->
          send_resp(conn, 503, "transfer revoked")
      end
    end
  end

  defp dispatch(conn, _service, _mode, _store, _sid, _stage, _limit, "nix-cache-info")
       when conn.method in ["GET", "HEAD"] do
    body = "StoreDir: /nix/store\nWantMassQuery: 0\nPriority: 30\n"
    conn |> put_resp_content_type("text/x-nix-cache-info") |> send_resp(200, body)
  end

  defp dispatch(conn, service, mode, store, sid, _stage, _limit, key)
       when conn.method in ["GET", "HEAD"] do
    cond do
      Narinfo.info?(key) ->
        case Garden.WorkStore.read(store, service, sid, key, mode) do
          {:ok, bytes, url, filename} ->
            :ok = Service.authorize(service, url, filename)
            conn |> put_resp_content_type("text/x-nix-narinfo") |> send_resp(200, bytes)

          {:error, :not_found} ->
            send_resp(conn, 404, "not found")

          {:error, :output_budget_exceeded} ->
            send_resp(conn, 413, "output budget exceeded")

          {:error, _} ->
            send_resp(conn, 503, "cache unavailable")
        end

      Narinfo.nar?(key) ->
        case Service.lookup(service, key) do
          {:ok, filename} ->
            case File.stat(filename) do
              {:ok, %{type: :regular, size: size}} ->
                conn =
                  conn
                  |> put_resp_content_type("application/x-nix-nar")
                  |> put_resp_header("content-length", Integer.to_string(size))

                send_file(conn, 200, filename)

              _ ->
                send_resp(conn, 404, "not found")
            end

          :error ->
            send_resp(conn, 404, "not found")
        end

      true ->
        send_resp(conn, 404, "not found")
    end
  end

  defp dispatch(conn, service, :write, store, sid, stage, limit, key) when conn.method == "PUT" do
    if Narinfo.info?(key) or Narinfo.nar?(key) do
      maximum = if Narinfo.info?(key), do: min(limit, 65_536), else: max(0, limit - 65_536)

      with {:ok, expected} <- content_length(conn, maximum),
           {:ok, token, filename} <- Service.begin_upload(service, key, expected) do
        result = upload(conn, filename, maximum)

        case result do
          {:ok, conn, size, digest} ->
            with :ok <- Service.finish_upload(service, token, size, digest),
                 :ok <- publish(store, service, sid, stage, key) do
              send_resp(conn, 200, "")
            else
              {:error, reason} -> reject(conn, reason)
            end

          {:error, conn, reason} ->
            Service.abandon(service, token)
            reject(conn, reason)
        end
      else
        {:error, reason} -> reject(conn, reason)
      end
    else
      send_resp(conn, 400, "invalid cache object")
    end
  end

  defp dispatch(conn, _service, _mode, _store, _sid, _stage, _limit, _key),
    do: send_resp(conn, 405, "method not allowed")

  defp publish(store, service, sid, stage, key) do
    if Narinfo.info?(key) do
      with {:ok, token} <- Service.lock(service) do
        result = Garden.WorkStore.commit(store, service, sid, stage, key, token)
        Service.unlock(service, token)

        case result do
          {:ok, _paths} -> :ok
          {:error, reason} -> {:error, reason}
        end
      else
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp content_length(conn, maximum) do
    case get_req_header(conn, "content-length") do
      [value] ->
        case Integer.parse(value) do
          {size, ""} when size >= 0 and size <= maximum -> {:ok, size}
          _ -> {:error, :staging_budget_exceeded}
        end

      [] ->
        {:ok, maximum}

      _ ->
        {:error, :invalid_length}
    end
  end

  defp upload(conn, filename, maximum) do
    case File.open(filename, [:write, :binary, :exclusive]) do
      {:ok, file} ->
        try do
          receive_body(conn, file, maximum, 0, :crypto.hash_init(:sha256))
        after
          File.close(file)
        end

      {:error, reason} ->
        {:error, conn, reason}
    end
  end

  defp receive_body(conn, file, maximum, size, hash) do
    case read_body(conn, length: 65_536, read_length: 65_536, read_timeout: 10_000) do
      {kind, bytes, conn} when kind in [:ok, :more] ->
        cond do
          size + byte_size(bytes) > maximum ->
            {:error, conn, :staging_budget_exceeded}

          true ->
            case :file.write(file, bytes) do
              :ok when kind == :ok ->
                {:ok, conn, size + byte_size(bytes),
                 :crypto.hash_final(:crypto.hash_update(hash, bytes))}

              :ok ->
                receive_body(
                  conn,
                  file,
                  maximum,
                  size + byte_size(bytes),
                  :crypto.hash_update(hash, bytes)
                )

              {:error, reason} ->
                {:error, conn, reason}
            end
        end

      {:error, reason} ->
        {:error, conn, reason}
    end
  end

  defp reject(conn, reason) do
    status =
      if reason in [:output_budget_exceeded, :staging_budget_exceeded, :cache_capacity_exhausted],
        do: 413,
        else: 409

    send_resp(conn, status, "cache upload rejected")
  end
end
