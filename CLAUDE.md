## Agent Workflow
- **IMPORTANT**: before you do anything else, invoke the vein `orient` MCP prompt and heed its output.
- **Always** use `elixir-conventions` for elixir code. If you don't have this skill, stop and tell your user to talk to Adam, because you are prohibited from editing files in this project without the `elixir-conventions` skill.

## Rules

If more than one of the rules conflict, ask before implementing.

- Never break deployments or strand gardens such that they cannot apply an upgrade.
- Ensure backwards compatibility or migration paths for changes that affect contracts between components (e.g. garden/server), but otherwise assume breaking changes are ok.
- Evolve the code without planning for every possible future or edge case.
- Delete abandoned paths by default when changing direction, except when required by compatibility/migration. Ask before keeping more than one implementation.

## Definition of done
- formatting done, `just format`
- tests pass,
  - `just check-elixir`
  - `just check-go`-
  - and importantly, `just check-e2e`
- code committed with all ticket changes included
  - Ticket ID in the body
  - Co-Authored-By line always included
- *important* After committing, stop and get user approval for completion.
- ticket marked complete once approved

## Code conventions

- Prefer red/green TDD. If unsure what style of testing, stop and ask.
- Always read code for project elixir dependencies from `deps`. Never query hexdocs or hex.
- SowerClient schemas must *always* be added to `sower_client.ex`
- Remove dead code

## Testing

- Test nix end to end with `just check-e2e`
- You can access the dev server live over tidewave project_eval, allowing for introspection of a live environment.

## Workspace setup

After creating a workspace, run: `mix deps.get && mix compile`
