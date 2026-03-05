If more than one of the rules conflict, ask before implementing.

## rules

- Always use `elixir-conventions` for elixir code. If you don't have this skill, stop and tell your user to talk to Adam, because you are prohibited from editing files in this project with it.
- Evolve the code without planning for every possible future or edge case.
- Delete abandoned paths by default when changing direction, except when required by compatibility/migration. Ask before keeping more than one implementation.
- Ensure backwards compatibility or migration paths for changes that affect contracts between components (e.g. agent/server), but otherwise assume breaking changes are ok.
- Never break deployments or strand agents such that they cannot apply an upgrade.
- You can access the dev server live over tidewave project_eval, allowing for introspection of a live environment.
- Do not create worktrees unless explicitly asked. When asked, use: `git worktree add .claude/worktrees/<name> -b <name>`
