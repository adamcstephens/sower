defmodule IncusClient.ApiClient do
  require Logger
  use TypedStruct

  typedstruct do
    field :url, String.t()
    field :unix_socket, String.t() | nil
  end

  def delete(path, params \\ %{}) do
    case Req.delete("#{config().url}#{path}", unix_socket: config().unix_socket, params: params) do
      {:ok, %{body: %{"type" => "async"}}} ->
        dbg("TODO ASYNC")
        :todo

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, response} ->
        status_code =
          case response.body do
            %{"type" => "error", "error_code" => code} -> code
            body -> body["status_code"]
          end
          |> to_string()

        schema =
          resolve_ref(
            spec().paths[handle_path_vars(path)].delete.responses[status_code]."$ref",
            spec()
          )

        case OpenApiSpex.cast_value(
               response.body,
               schema,
               spec()
             ) do
          {_, %{:type => "error"} = err} -> {:error, err}
          valid -> valid
        end

      {:error, _} = err ->
        err
    end
  end

  def get(path, params) do
    path_merged =
      Path.split(path)
      |> Enum.map(fn p ->
        case Regex.run(~r"{([[:alpha:]]*)}", p) do
          nil -> p
          [_, param] -> params[:"#{param}"]
        end
      end)
      |> Path.join()

    case Req.get("#{config().url}#{path_merged}",
           unix_socket: config().unix_socket,
           params: params
         ) do
      {:ok, response} ->
        status_code =
          case response.body do
            %{"type" => "error", "error_code" => code} -> code
            body -> body["status_code"]
          end
          |> to_string()

        schema = resolve_response_schema(path, :get, status_code)

        case OpenApiSpex.cast_value(
               response.body,
               schema,
               spec()
             ) do
          {_, %{:type => "error"} = err} -> {:error, err}
          valid -> valid
        end

      {:error, _} = err ->
        err
    end
  end

  def post(path, request, params \\ []) do
    req_schema =
      spec().paths[path].post.requestBody.content["application/json"].schema

    case OpenApiSpex.cast_value(request, req_schema, spec()) do
      {:ok, valid} ->
        req_response =
          Req.post!("#{config().url}#{path}",
            json: valid,
            unix_socket: config().unix_socket,
            params: params
          )

        case req_response do
          %{body: %{"type" => "async"}} ->
            dbg("TODO ASYNC")
            :todo

          _ ->
            status_code =
              case req_response.body do
                %{"type" => "error", "error_code" => code} -> code
                body -> body["status_code"]
              end
              |> to_string()

            schema = resolve_response_schema(path, :post, status_code)

            case OpenApiSpex.cast_value(
                   req_response.body,
                   schema,
                   spec()
                 ) do
              {_, %{:type => "error"} = err} -> {:error, err}
              valid -> valid
            end
        end

      {:error, error} ->
        {:error, error}
    end
  end

  def init() do
    spec =
      "../../priv/incus-rest-api.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> OpenApiSpex.OpenApi.Decode.decode()

    :persistent_term.put(:incus_openapi_spec, spec)

    config_url = Application.get_env(:incus_client, :url, "unix:///var/lib/incus/unix.socket")

    url =
      if String.starts_with?(config_url, "unix://") do
        "http://"
      else
        config_url
      end

    unix_socket =
      if String.starts_with?(config_url, "unix://") do
        String.replace(config_url, "unix://", "")
      else
        nil
      end

    Application.put_env(:incus_client, __MODULE__, %__MODULE__{
      unix_socket: unix_socket,
      url: url
    })

    Logger.debug(msg: "Incus Client init complete")
  end

  defp resolve_ref(ref, spec \\ spec()) do
    [top, type, key] = ref |> String.split("/") |> Enum.reject(&(&1 == "#"))

    spec
    |> Map.fetch!(String.to_existing_atom(top))
    |> Map.fetch!(String.to_existing_atom(type))
    |> Map.fetch!(key)
    |> Map.fetch!(:content)
    |> Map.fetch!("*/*")
    |> Map.fetch!(:schema)
  end

  defp handle_path_vars(path) do
    case path |> Path.split() do
      ["/", ver, type, _object] -> Path.join(["/", ver, type, "{name}"])
      ["/", _ver, _type] -> path
    end
  end

  def resolve_response_schema(path, method, status_code, spec \\ spec())

  def resolve_response_schema(_, _, status_code, spec)
      when status_code == 404 or status_code == "404" do
    resolve_ref("#/components/responses/NotFound", spec)
  end

  def resolve_response_schema(path, method, status_code, spec) do
    case spec
         |> Map.get(:paths)
         |> Map.get(path)
         |> Map.get(method)
         |> Map.get(:responses)
         |> Map.get(to_string(status_code)) do
      %OpenApiSpex.Response{content: %{"application/json" => %{schema: schema}}} -> schema
      %OpenApiSpex.Reference{"$ref": ref} -> resolve_ref(ref)
    end
  end

  # schema =
  #   resolve_ref(
  #     spec().paths[path].post.responses[status_code]."$ref",
  #     spec()
  #   )

  defp spec() do
    :persistent_term.get(:incus_openapi_spec)
  end

  defp config() do
    Application.get_env(:incus_client, __MODULE__)
  end
end
