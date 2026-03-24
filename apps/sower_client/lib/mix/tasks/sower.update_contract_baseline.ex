defmodule Mix.Tasks.Sower.UpdateContractBaseline do
  @moduledoc """
  Regenerates the contract baseline file from current server-pushed schemas.

  The baseline captures the shape of schemas that the server pushes to gardens.
  Contract evolution tests compare live schemas against this baseline to catch
  breaking changes that would prevent old gardens from decoding deployments.

  ## Usage

      mix sower.update_contract_baseline

  ## Output

  Writes `test/fixtures/contract_baseline.json` with the structural shape of
  each server-pushed schema (property names, types, required fields, defaults,
  nullability).
  """

  use Mix.Task

  @baseline_path "apps/sower_client/test/fixtures/contract_baseline.json"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("compile")

    spec = SowerClient.spec()

    baseline =
      SowerClient.server_pushed_schema_titles()
      |> Enum.map(fn title ->
        schema = Map.fetch!(spec.components.schemas, title)
        {title, extract_shape(schema)}
      end)
      |> Enum.into(%{})

    json = Jason.encode!(baseline, pretty: true)
    File.mkdir_p!(Path.dirname(@baseline_path))
    File.write!(@baseline_path, json <> "\n")

    Mix.shell().info("Wrote contract baseline to #{@baseline_path}")
  end

  defp extract_shape(schema) do
    properties =
      (schema.properties || %{})
      |> Enum.map(fn {name, prop} -> {to_string(name), extract_property(prop)} end)
      |> Enum.sort()
      |> Enum.into(%{})

    required =
      (schema.required || [])
      |> Enum.map(&to_string/1)
      |> Enum.sort()

    %{"required" => required, "properties" => properties}
  end

  defp extract_property(%OpenApiSpex.Reference{"$ref": ref}) do
    title = ref |> String.split("/") |> List.last()
    %{"type" => "object", "ref" => title}
  end

  defp extract_property(%OpenApiSpex.Schema{} = prop) do
    shape = %{"type" => to_string(prop.type)}

    shape =
      if prop.default != nil do
        Map.put(shape, "has_default", true)
      else
        shape
      end

    shape =
      if prop.nullable do
        Map.put(shape, "nullable", true)
      else
        shape
      end

    shape =
      case prop.items do
        %OpenApiSpex.Reference{"$ref": ref} ->
          title = ref |> String.split("/") |> List.last()
          Map.put(shape, "items_ref", title)

        _ ->
          shape
      end

    shape
  end
end
