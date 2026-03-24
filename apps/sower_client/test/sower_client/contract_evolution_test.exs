defmodule SowerClient.ContractEvolutionTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Verifies schema evolution rules on server-pushed schemas.

  The server pushes these schemas to gardens (e.g. Deployment broadcasts).
  Old gardens must be able to decode payloads from newer servers, so we
  enforce:

  - No new required fields (old clients won't send/expect them)
  - No removed properties (old clients may still reference them)
  - No type changes (old clients expect the original type)

  To intentionally update the contract (with a migration path), run:

      mix sower.update_contract_baseline
  """

  @baseline_path Path.expand("../fixtures/contract_baseline.json", __DIR__)

  @server_pushed_schemas SowerClient.server_pushed_schema_titles()

  setup_all do
    baseline = @baseline_path |> File.read!() |> Jason.decode!()
    spec = SowerClient.spec()
    {:ok, baseline: baseline, spec: spec}
  end

  for title <- @server_pushed_schemas do
    describe "#{title}" do
      test "no new required fields", %{baseline: baseline, spec: spec} do
        old = baseline[unquote(title)]
        current = spec.components.schemas[unquote(title)]

        old_required = MapSet.new(old["required"])

        new_required =
          (current.required || [])
          |> Enum.map(&to_string/1)
          |> MapSet.new()

        added = MapSet.difference(new_required, old_required)

        assert MapSet.size(added) == 0,
               "#{unquote(title)}: added required fields #{inspect(MapSet.to_list(added))}. " <>
                 "Old gardens won't send these. Make them optional with defaults, " <>
                 "or run `mix sower.update_contract_baseline` after ensuring a migration path."
      end

      test "no removed properties", %{baseline: baseline, spec: spec} do
        old = baseline[unquote(title)]
        current = spec.components.schemas[unquote(title)]

        old_props = MapSet.new(Map.keys(old["properties"]))

        new_props =
          current.properties
          |> Map.keys()
          |> Enum.map(&to_string/1)
          |> MapSet.new()

        removed = MapSet.difference(old_props, new_props)

        assert MapSet.size(removed) == 0,
               "#{unquote(title)}: removed properties #{inspect(MapSet.to_list(removed))}. " <>
                 "Old gardens may still reference these. " <>
                 "Run `mix sower.update_contract_baseline` after ensuring a migration path."
      end

      test "no type changes", %{baseline: baseline, spec: spec} do
        old = baseline[unquote(title)]
        current = spec.components.schemas[unquote(title)]

        for {prop_name, old_prop} <- old["properties"] do
          case Map.get(current.properties, String.to_existing_atom(prop_name)) do
            %OpenApiSpex.Schema{} = current_prop ->
              assert to_string(current_prop.type) == old_prop["type"],
                     "#{unquote(title)}.#{prop_name}: type changed " <>
                       "from #{old_prop["type"]} to #{current_prop.type}. " <>
                       "Run `mix sower.update_contract_baseline` after ensuring a migration path."

            %OpenApiSpex.Reference{} ->
              assert old_prop["type"] == "object",
                     "#{unquote(title)}.#{prop_name}: was #{old_prop["type"]}, " <>
                       "now a $ref (object). " <>
                       "Run `mix sower.update_contract_baseline` after ensuring a migration path."

            nil ->
              :ok
          end
        end
      end
    end
  end
end
