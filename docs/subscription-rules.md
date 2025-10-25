# Subscription Rules

Subscription rules allow agents to filter seeds based on tag values when requesting deployments.

## Overview

When an agent subscribes to a seed, it can optionally specify rules that filter seeds by their tags. Only seeds matching ALL rules will be selected for deployment.

## Agent Configuration

Configure subscriptions with rules in your agent config file or `config/runtime.exs`:

```elixir
subscriptions: [
  %{
    seed_name: "myhost",
    seed_type: "nixos",
    rules: [
      %{key: "branch", op: "eq", value: "main"},
      %{key: "repo", op: "eq", value: "https://github.com/example/repo"}
    ]
  },
  # Subscription without rules matches any seed with matching name/type
  %{
    seed_name: "myhost",
    seed_type: "home-manager"
  }
]
```

## Rule Schema

Each rule has three fields:

- **key** (string): The tag key to match (e.g., "branch", "repo", "environment")
- **op** (string): The comparison operation. Currently supports:
  - `"eq"` - Equality check
- **value** (string): The value to match against

## Seed Matching Behavior

When a deployment is requested for a subscription with rules:

1. Filter seeds by `seed_name` and `seed_type`
2. For each rule, filter seeds that have a matching tag with `key` and `value`
3. ALL rules must match (AND logic)
4. Return the latest matching seed (by `inserted_at`)

### Examples

**Seed 1:**
```elixir
%{
  name: "myhost",
  seed_type: "nixos",
  artifact: "/nix/store/abc...",
  tags: [
    %{key: "branch", value: "main"},
    %{key: "repo", value: "https://github.com/example/repo"}
  ]
}
```

**Seed 2:**
```elixir
%{
  name: "myhost",
  seed_type: "nixos",
  artifact: "/nix/store/def...",
  tags: [
    %{key: "branch", value: "dev"}
  ]
}
```

**Subscription:**
```elixir
%{
  seed_name: "myhost",
  seed_type: "nixos",
  rules: [
    %{key: "branch", op: "eq", value: "main"}
  ]
}
```

**Result:** Seed 1 matches (has branch=main). Seed 2 does not match (has branch=dev).

## Creating Seeds with Tags

When submitting seeds via CLI or API, include tags:

```bash
# CLI (not yet implemented - placeholder)
sower seed submit --name myhost --type nixos \
  --artifact /nix/store/... \
  --tag branch=main \
  --tag repo=https://github.com/example/repo
```

Server-side Elixir:
```elixir
Sower.Seed.create(%{
  name: "myhost",
  seed_type: "nixos",
  artifact: "/nix/store/...",
  tags: [
    %{key: "branch", value: "main"},
    %{key: "repo", value: "https://github.com/example/repo"}
  ]
})
```

## Future Enhancements

Potential future rule operators:
- `ne` - Not equal
- `in` - Value in list
- `regex` - Regular expression match
- `gt`, `lt` - Greater/less than (for version comparisons)
