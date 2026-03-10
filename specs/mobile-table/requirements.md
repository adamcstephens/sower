# Requirements: Mobile-Responsive Table

## Goal

Replace the fixed-width `.table` component (core_components) with a new responsive table in sower_components that hides low-priority columns on mobile via `hide_on={:mobile}`, then migrate all 9 `.table` instances to it.

## User Stories

### US-1: Responsive Table Component
**As a** developer
**I want to** mark columns with `hide_on={:mobile}`
**So that** tables degrade gracefully on small screens without switching to card layout

**Acceptance Criteria:**
- [ ] AC-1.1: New `table` component exists in `sower_components.ex` with same API as core `.table` (id, rows, row_id, row_click, row_item, :col, :action slots)
- [ ] AC-1.2: `:col` slot accepts optional `hide_on` attr with value `:mobile`
- [ ] AC-1.3: When `hide_on={:mobile}`, both `<th>` and `<td>` render with classes `hidden sm:table-cell`
- [ ] AC-1.4: Columns without `hide_on` are always visible
- [ ] AC-1.5: `:action` columns are always visible (no `hide_on` support)
- [ ] AC-1.6: Table wrapped in `overflow-x-auto` container
- [ ] AC-1.7: LiveStream (`phx-update="stream"`) works identically to core `.table`
- [ ] AC-1.8: Dark mode styling preserved

### US-2: Multi-Column Table Migrations
**As a** user viewing data tables on mobile
**I want to** see the primary identifier column with secondary columns hidden
**So that** the table fits my screen without horizontal scrolling

**Acceptance Criteria:**
- [ ] AC-2.1: `agent_live/index.html.heex` migrated; Online and Latest Deployment columns have `hide_on={:mobile}`
- [ ] AC-2.2: `seed_live/index.html.heex` migrated; Type and Updated columns have `hide_on={:mobile}`
- [ ] AC-2.3: `nix/cache_live/index.html.heex` migrated; Public Key column has `hide_on={:mobile}`
- [ ] AC-2.4: `settings/access_token_live/index.html.heex` migrated; Token and Expires columns have `hide_on={:mobile}`
- [ ] AC-2.5: `forge/connection_live/index.html.heex` migrated; URL and Type columns have `hide_on={:mobile}`
- [ ] AC-2.6: `deployment_live/index.ex` migrated; Agent and Completed columns have `hide_on={:mobile}`
- [ ] AC-2.7: All action columns always visible across all tables
- [ ] AC-2.8: All existing tests pass for migrated views

### US-3: Single-Column Table Migrations
**As a** developer
**I want to** migrate remaining single-column tables to the new component
**So that** all `.table` usages are consolidated in sower_components

**Acceptance Criteria:**
- [ ] AC-3.1: `subscription_live/index.html.heex` uses new sower `table`
- [ ] AC-3.2: `settings/access_token_live/show.html.heex` uses new sower `table`
- [ ] AC-3.3: `forge/connection_live/show.html.heex` (both tables) uses new sower `table`
- [ ] AC-3.4: No `hide_on` needed — just component swap
- [ ] AC-3.5: All existing tests pass for migrated views

## Functional Requirements

| ID | Requirement | Priority | Acceptance Criteria |
|----|-------------|----------|---------------------|
| FR-1 | New `table` component in `sower_components.ex` | High | AC-1.1 through AC-1.8 |
| FR-2 | `hide_on` attr on `:col` slot, values: `[:mobile, nil]` | High | AC-1.2, AC-1.3, AC-1.4 |
| FR-3 | `hidden sm:table-cell` as complete static class strings (Tailwind JIT) | High | AC-1.3 |
| FR-4 | Hide classes applied to both `<th>` and `<td>` | High | AC-1.3 |
| FR-5 | Migrate 6 multi-column tables with appropriate `hide_on` | High | AC-2.1 through AC-2.8 |
| FR-6 | Migrate 3 single-column table instances | Medium | AC-3.1 through AC-3.5 |

## Non-Functional Requirements

| ID | Requirement | Metric | Target |
|----|-------------|--------|--------|
| NFR-1 | No horizontal scroll on mobile for multi-column tables | Visual check at 320px viewport | Tables fit without scroll |
| NFR-2 | All existing tests pass | `mix test` | Zero failures |
| NFR-3 | No Tailwind JIT issues | `mix assets.build` | All responsive classes in output CSS |
| NFR-4 | Dark mode support | Visual check | Matches existing `.table` dark mode |

## Out of Scope

- Modifying `.responsive_table` component (stays as-is)
- `hide_on` values beyond `:mobile` (no `:tablet`/`:desktop` — YAGNI)
- Card layout on mobile (that's what `.responsive_table` does)
- Removing core `.table` from core_components.ex (may be used by Phoenix generators)
- Sortable columns
- Column reordering

## Dependencies

- Phoenix LiveView 1.1.0 (already in project)
- Tailwind CSS with JIT mode (already configured)
- LiveStream support (already working in core `.table`)

## Glossary

- **hide_on**: Slot attribute declaring at which breakpoint a column becomes hidden
- **Column prioritization**: Showing only essential columns on small screens, hiding secondary ones
- **LiveStream**: Phoenix mechanism for efficient list rendering via `phx-update="stream"`

## Migration Target Summary

| File | Columns | hide_on Columns |
|------|---------|-----------------|
| agent_live/index | Name, Online, Latest Deploy + actions | Online, Latest Deploy |
| seed_live/index | Name, Type, Updated + action | Type, Updated |
| subscription_live/index | SID + actions | — (single col) |
| nix/cache_live/index | URL, Public Key + actions | Public Key |
| access_token_live/index | Description, Token, Expires + actions | Token, Expires |
| access_token_live/show | Permissions | — (single col) |
| forge/connection_live/index | Name, URL, Type + actions | URL, Type |
| forge/connection_live/show (x2) | repo name + action | — (single col) |
| deployment_live/index | Status, SID, Agent, Completed + actions | Agent, Completed |

## Success Criteria

- All 9 `.table` instances migrated to new sower `table`
- Multi-column tables readable on 320px-wide viewport without horizontal scroll
- `mix test` passes with zero failures
- No changes to `.responsive_table` or its usages
