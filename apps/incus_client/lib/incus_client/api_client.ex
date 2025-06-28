defmodule IncusClient.ApiClient do
  use GenServer
  use TypedStruct

  typedstruct do
    field :url, String.t()
    field :unix_socket, String.t() | nil
    field :spec, map()
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def delete(path, request \\ %{}) do
    GenServer.call(__MODULE__, {:delete, path, request})
  end

  def get(path) do
    GenServer.call(__MODULE__, {:get, path})
  end

  def post(path, request) do
    GenServer.call(__MODULE__, {:post, path, request})
  end

  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  # Server Callbacks

  @impl GenServer
  def init(_) do
    spec =
      "../../priv/incus-rest-api.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> OpenApiSpex.OpenApi.Decode.decode()

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

    state = %__MODULE__{
      spec: spec,
      unix_socket: unix_socket,
      url: url
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call({:get, path}, _from, state) do
    response = Req.get!("#{state.url}#{path}", unix_socket: state.unix_socket)

    reply =
      OpenApiSpex.cast_value(
        response.body,
        state.spec.paths[path].get.responses["#{response.status}"].content["application/json"].schema,
        state.spec
      )

    {:reply, reply, state}
  end

  def handle_call({:post, path, request}, _from, state) do
    req_schema = state.spec.paths[path].post.requestBody.content["application/json"].schema

    response =
      case OpenApiSpex.cast_value(request, req_schema, state.spec) do
        {:ok, valid} ->
          req_response =
            Req.post!("#{state.url}#{path}", json: valid, unix_socket: state.unix_socket)

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

              schema =
                resolve_ref(
                  state.spec.paths[path].post.responses[status_code]."$ref",
                  state.spec
                )

              case OpenApiSpex.cast_value(
                     req_response.body,
                     schema,
                     state.spec
                   ) do
                {_, %{:type => "error"} = err} -> {:error, err}
                valid -> valid
              end
          end

        {:error, error} ->
          {:error, error}
      end

    {:reply, response, state}
  end

  def handle_call({:delete, path, params}, _from, state) do
    response =
      Req.delete!("#{state.url}#{path}",
        unix_socket: state.unix_socket,
        params: params
      )

    reply =
      case response do
        %{body: %{"type" => "async"}} ->
          dbg("TODO ASYNC")
          :todo

        %{status: 404} ->
          {:error, :not_found}

        _ ->
          status_code =
            case response.body do
              %{"type" => "error", "error_code" => code} -> code
              body -> body["status_code"]
            end
            |> to_string()

          schema =
            resolve_ref(
              state.spec.paths[handle_path_vars(path)].delete.responses[status_code]."$ref",
              state.spec
            )

          case OpenApiSpex.cast_value(
                 response.body,
                 schema,
                 state.spec
               ) do
            {_, %{:type => "error"} = err} -> {:error, err}
            valid -> valid
          end
      end

    {:reply, reply, state}
  end

  defp resolve_ref(ref, spec) do
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
    case path |> String.split("/") do
      ["", ver, type, _object] -> Enum.join(["", ver, type, "{name}"], "/")
      ["", _ver, _type] -> path
    end
  end
end
