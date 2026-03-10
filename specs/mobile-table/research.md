# Research: mobile-table

## Executive Summary

Tailwind's mobile-first `hidden sm:table-cell` pattern is the established way to hide table columns on small screens while preserving real HTML table layout. The project has a `.table` component in `core_components.ex` (fixed 40rem width, not responsive) and a `.responsive_table` in `sower_components.ex` (card-stacking on mobile). The goal is to create a new `sower_components` table based on `.table` that uses column prioritization via `hide_on={:mobile}` on `:col` slots, keeping `.responsive_table` as-is.

## External Research

### Best Practices
- **Core pattern**: `hidden sm:table-cell` — mobile-first, hidden by default, shown >= 640px
- Must use `table-cell` not `block` at breakpoints — `block` breaks header alignment
- Must apply hide classes to BOTH `<th>` and `<td>` or column count mismatches break layout
- Tailwind JIT requires complete static class strings; `"hidden #{bp}:table-cell"` won't be detected
- Always wrap table in `overflow-x-auto` as safety net for edge cases
- `display: none` (via `hidden`) is correct for accessibility; `visibility: hidden`/`collapse` reserves space

### Prior Art
- jQuery Mobile pioneered `data-priority` attributes (1-6 tiers) — our simpler `hide_on={:mobile}` is better: only two states, declarative at call site
- Phoenix core_components table uses `:col` and `:action` slots — extending with `hide_on` attr is straightforward via `attr :hide_on, :atom, values: [:mobile, nil]`

### Pitfalls to Avoid
| Pitfall | Fix |
|---------|-----|
| Using `block` instead of `table-cell` | Always use `sm:table-cell` |
| Hiding `<th>` but not `<td>` | Apply same classes to both |
| Dynamic class construction | Use complete static strings |
| `visibility: hidden` / `collapse` | Use `hidden` utility |
| Forgetting `overflow-x-auto` wrapper | Always wrap |
| Hiding too many columns | Keep primary ID + actions visible |

## Codebase Analysis

### Existing Patterns

**`.table` component** (`core_components.ex` lines 403-481):
- Attributes: `id` (required), `rows` (required), `row_id`, `row_click`, `row_item`
- Slots: `:col` (required, with `label`), `:action` (optional)
- CSS: `w-[40rem] mt-11 sm:w-full` — 40rem fixed on mobile, full on sm+
- Container: `overflow-y-auto px-4 sm:overflow-visible sm:px-0`
- Supports LiveStream via `phx-update="stream"`

**`.responsive_table` component** (`sower_components.ex` lines 61-114):
- Same base attributes, but no `:action` slot
- Uses `data-label` on TDs for CSS mobile labels
- CSS class `responsive-table` triggers media query card-stacking in `app.css`

### All Table Usages

**Using `.table` (9 instances, targets for migration):**
1. `agent_live/index.html.heex` — Name, Online, Latest Deployment + Edit/Delete actions
2. `seed_live/index.html.heex` — Name, Type, Updated + Show action
3. `subscription_live/index.html.heex` — SID + Edit/Delete actions
4. `nix/cache_live/index.html.heex` — URL, Public Key + Edit/Delete actions
5. `settings/access_token_live/index.html.heex` — Description, Token, Expires + Edit/Delete actions
6. `settings/access_token_live/show.html.heex` — Permissions (single col, no actions)
7. `forge/connection_live/index.html.heex` — Name, URL, Type + Edit/Delete actions
8. `forge/connection_live/show.html.heex` — 2 tables: repos (1 col + action), available repos (1 col + action)
9. `deployment_live/index.ex` — Status, SID, Agent, Completed + Retry/Show actions

**Using `.responsive_table` (keep as-is):**
1. `subscription_live/show.html.heex` — Matching Seeds (4 cols), Deployments (3 cols)
2. `agent_live/show.html.heex` — Seed Gens (5 cols), Subscriptions (4 cols), Deployments (4 cols)
3. `deployment_live/show.ex` — Subscriptions (1 col)

### Column Analysis for Migration Targets

| Table | Always Show | Can Hide on Mobile |
|-------|------------|-------------------|
| Agent Index | Name | Online, Latest Deployment |
| Seed Index | Name | Type, Updated |
| Subscription Index | SID | — (single col) |
| Nix Cache Index | URL | Public Key |
| Access Token Index | Description | Token, Expires |
| Access Token Show | Permissions | — (single col) |
| Forge Connection Index | Name | URL, Type |
| Forge Connection Show (x2) | repo name | — (single col) |
| Deployment Index | Status, SID | Agent, Completed |

### Dependencies
- Phoenix LiveView 1.1.0
- Tailwind CSS with `@tailwindcss/forms` plugin
- LiveStream support required
- Dark mode support throughout

### Constraints
- Single-column tables (subscription index, access token show, forge connection show) don't need `hide_on` — just component swap
- 6 multi-column tables benefit from `hide_on`: agent index, seed index, nix cache index, access token index, forge connection index, deployment index
- Actions must always be visible per user requirement

## Quality Commands

| Type | Command |
|------|---------|
| Format | `mix format --check-formatted` |
| Tests | `mix test` |
| Compile | `mix compile --warnings-as-errors` |
| Full check | `just check` |

## Feasibility Assessment

| Aspect | Assessment | Notes |
|--------|-----------|-------|
| Technical complexity | Low | Straightforward slot attr extension |
| Risk | Low | No breaking changes, additive feature |
| Effort | Small | ~3 files to modify, 3 templates to migrate |
| Testing | Low | Existing tests + visual verification |

## Recommendations for Requirements
1. Create new `table` component in `sower_components.ex` based on core `.table`
2. Add `hide_on` attr to `:col` slot with `:mobile` value
3. Apply `hidden sm:table-cell` to both `<th>` and `<td>` when `hide_on == :mobile`
4. Wrap in `overflow-x-auto` container
5. Migrate 3 `.table` usages to new component
6. Keep `.responsive_table` untouched

## Open Questions
- Should `hide_on` support `:tablet` (md breakpoint) in future? Start with `:mobile` only per YAGNI.

## Sources
- Tailwind CSS Display docs, Responsive Design docs
- Phoenix core_components.ex source
- jQuery Mobile Column Toggle Widget (historical reference)
- Project codebase: core_components.ex, sower_components.ex, app.css
