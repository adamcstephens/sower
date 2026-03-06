defmodule SowerWeb.Api.SeedController do
  use SowerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias OpenApiSpex.Schema
  import Sower.Authorization

  plug OpenApiSpex.Plug.CastAndValidate, json_render_error_v2: true

  action_fallback SowerWeb.Api.FallbackController

  operation(:create,
    operation_id: "NewSeed",
    summary: "New Seed",
    parameters: [
      rename: [
        description: "Rename the seed if matching artifact found",
        type: :boolean,
        example: "true"
      ]
    ],
    request_body: {"Seed params", "application/json", SowerClient.Seed},
    responses: %{
      created: {"Seed response", "application/json", SowerClient.Seed},
      conflict:
        {"Seed conflict response", "application/json",
         %Schema{type: :object, properties: %{error: %Schema{type: :string}}}},
      unauthorized:
        {"Unauthorized", "application/json",
         %Schema{type: :object, properties: %{error: %Schema{type: :string}}}}
    }
  )

  def create(
        %Plug.Conn{
          body_params: %SowerClient.Seed{
            name: name,
            seed_type: seed_type,
            artifact: artifact,
            tags: tags
          },
          query_params: query_params
        } = conn,
        _params
      ) do
    rename = Map.get(query_params, "rename") in ["true"]
    conn = Map.put(conn, :body_params, %{})

    if can(conn.assigns.access_token)
       |> create?(%Sower.Orchestration.Seed{org_id: conn.assigns.access_token.org_id}) do
      seed_attrs = %{name: name, seed_type: seed_type, artifact: artifact}

      seed_attrs =
        case tags do
          nil ->
            seed_attrs

          tags when is_list(tags) ->
            Map.put(seed_attrs, :tags, Enum.map(tags, &Map.from_struct/1))
        end

      case Sower.Orchestration.Seed.create(seed_attrs, rename: rename) do
        {:ok, %Sower.Orchestration.Seed{} = seed} ->
          conn
          |> put_status(:created)
          |> render(:show, seed: seed)

        {:error, %Ecto.Changeset{errors: errors}} ->
          Logger.error(error: "Failed to create seed", errors: errors)
          conn |> put_status(409) |> render(:error, error: "Failed to create seed")
      end
    else
      conn |> put_status(401) |> render(:error, error: "unauthorized")
    end
  end

  operation(:latest,
    operation_id: "LatestSeed",
    summary: "Find latest Seed",
    parameters: [
      OpenApiSpex.Operation.parameter(
        :tags,
        :query,
        %Schema{type: :array, items: %Schema{type: :string}},
        "Filter by tags (key=value format, can repeat)"
      ),
      name: [
        description: "Seed name",
        type: :string,
        example: "host1"
      ],
      seed_type: [
        description: "Seed type",
        type: :string,
        example: "nixos"
      ]
    ],
    responses: %{
      ok: {"Seed response", "application/json", SowerClient.Seed},
      not_found:
        {"Seed error response", "application/json",
         %Schema{type: :object, properties: %{error: %Schema{type: :string}}}},
      unauthorized:
        {"Unauthorized", "application/json",
         %Schema{type: :object, properties: %{error: %Schema{type: :string}}}}
    }
  )

  def latest(conn, %{name: name, seed_type: seed_type} = params) do
    if can(conn.assigns.access_token)
       |> read?(%Sower.Orchestration.Seed{org_id: conn.assigns.access_token.org_id}) do
      tags = parse_tags(params[:tags])

      case Sower.Orchestration.Seed.latest(name, seed_type, tags) do
        nil ->
          conn |> put_status(404) |> render(:not_found)

        seed ->
          render(conn, :show, seed: seed)
      end
    else
      conn |> put_status(401) |> render(:error, error: "unauthorized")
    end
  end

  defp parse_tags(nil), do: []

  defp parse_tags(tags) when is_list(tags) do
    Enum.map(tags, fn tag ->
      [key, value] = String.split(tag, "=", parts: 2)
      %{key: key, value: value}
    end)
  end

  operation(:get,
    operation_id: "GetSeed",
    summary: "Get Seed",
    parameters: [
      sid: [
        in: :path,
        description: "Seed SID",
        type: :string,
        example: "example4ser3adju75ddusbr"
      ]
    ],
    responses: [
      ok: {"Seed response", "application/json", SowerClient.Seed},
      not_found:
        {"Seed error response", "application/json",
         %Schema{type: :object, properties: %{error: %Schema{type: :string}}}},
      unauthorized:
        {"Unauthorized", "application/json",
         %Schema{type: :object, properties: %{error: %Schema{type: :string}}}}
    ]
  )

  def get(conn, %{sid: sid}) do
    if conn.assigns.access_token
       |> can()
       |> read?(%Sower.Orchestration.Seed{org_id: conn.assigns.access_token.org_id}) do
      case Sower.Orchestration.Seed.get_sid(sid) do
        nil ->
          conn |> put_status(404) |> render(:error, error: "not found")

        seed ->
          render(conn, :show, seed: seed)
      end
    else
      conn |> put_status(401) |> render(:error, error: "unauthorized")
    end
  end

  def get(conn, _) do
    if can(conn.assigns.access_token)
       |> read?(%Sower.Orchestration.Seed{org_id: conn.assigns.access_token.org_id}) do
      conn |> put_status(:not_found) |> render(:not_found)
    else
      conn |> put_status(401) |> render(:error, error: "unauthorized")
    end
  end

  operation(:list,
    operation_id: "ListSeeds",
    summary: "List Seeds",
    parameters: [
      name: [
        description: "Seed name",
        type: :string,
        example: "host1"
      ],
      seed_type: [
        description: "Seed type, one of [#{SowerClient.Seed.seed_types() |> Enum.join(", ")}]",
        type: :string,
        example: "nixos"
      ]
    ],
    responses: [
      ok: {"Seed response", "application/json", %Schema{type: :array, items: SowerClient.Seed}},
      unauthorized:
        {"Unauthorized", "application/json",
         %Schema{type: :object, properties: %{error: %Schema{type: :string}}}},
      not_found:
        {"Seed error response", "application/json",
         %Schema{type: :object, properties: %{error: %Schema{type: :string}}}}
    ]
  )

  def list(conn, %{name: name, seed_type: seed_type}) do
    if can(conn.assigns.access_token)
       |> read?(%Sower.Orchestration.Seed{org_id: conn.assigns.access_token.org_id}) do
      seed = Sower.Orchestration.Seed.get(name, seed_type)

      case seed do
        nil ->
          conn |> put_status(:not_found) |> render(:not_found)

        seeds ->
          render(conn, :list, seeds: seeds)
      end
    else
      conn |> put_status(401) |> render(:error, error: "unauthorized")
    end
  end

  def list(conn, _) do
    if can(conn.assigns.access_token)
       |> read?(%Sower.Orchestration.Seed{org_id: conn.assigns.access_token.org_id}) do
      seeds = Sower.Orchestration.Seed.list()
      render(conn, :list, seeds: seeds)
    else
      conn |> put_status(401) |> render(:error, error: "unauthorized")
    end
  end
end
