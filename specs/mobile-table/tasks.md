# Tasks: Mobile-Responsive Table

## Phase 1: Red-Green-Yellow Cycles

Focus: TDD implementation of the table component and migration of all 9 instances.

- [x] 1.1 [RED] Failing test: table/1 renders with hide_on={:mobile} classes
  - **Do**:
    1. Create test in `sower_components_test.exs` for the new `table/1` component
    2. Test 1: renders a basic table with columns (no hide_on) — all `<th>` and `<td>` visible
    3. Test 2: renders a column with `hide_on={:mobile}` — both `<th>` and `<td>` have `hidden` and `sm:table-cell` classes
    4. Test 3: action columns never get hide classes
  - **Files**: apps/sower/test/sower_web/components/sower_components_test.exs
  - **Done when**: Tests exist and fail (table/1 not defined yet)
  - **Verify**: `cd /home/adam/projects/sower/.worktrees/mobile-table && mix test test/sower_web/components/sower_components_test.exs 2>&1 | grep -q "FAIL\|Error\|error\|undefined" && echo RED_PASS`
  - **Commit**: `test(table): red - failing tests for table/1 with hide_on`
  - _Requirements: FR-1, FR-2, AC-1.1, AC-1.2, AC-1.3, AC-1.4, AC-1.5_

- [x] 1.2 [GREEN] Implement table/1 in sower_components.ex
  - **Do**:
    1. Add `table/1` function to `sower_components.ex` with the HEEx template from design.md
    2. Define attrs: id (:string, required), rows (:list, required), row_id (:any), row_click (:any), row_item (:any, default &Function.identity/1)
    3. Define slots: :col (required, with label :string and hide_on :atom attrs), :action
    4. Apply `hidden sm:table-cell` classes when `col[:hide_on] == :mobile` on both `<th>` and `<td>`
  - **Files**: apps/sower/lib/sower_web/components/sower_components.ex
  - **Done when**: Tests from 1.1 pass
  - **Verify**: `cd /home/adam/projects/sower/.worktrees/mobile-table && mix test test/sower_web/components/sower_components_test.exs`
  - **Commit**: `feat(table): green - implement table/1 with hide_on support`
  - _Requirements: FR-1, FR-2, FR-3, FR-4, AC-1.1 through AC-1.8_
  - _Design: Component Design, HEEx Template_

- [x] 1.3 [VERIFY] Quality checkpoint after component implementation
  - **Do**: Run compile, format, and test suite
  - **Verify**: `cd /home/adam/projects/sower/.worktrees/mobile-table && mix compile --warnings-as-errors && mix format --check-formatted && mix test`
  - **Done when**: All commands exit 0
  - **Commit**: `chore(table): pass quality checkpoint` (only if fixes needed)

- [x] 1.4 [RED] Failing test: global import resolves table/1 to SowerComponents
  - **Do**:
    1. Add a test that verifies SowerComponents.table/1 is callable from a module that uses `SowerWeb, :live_view` (or assert the import wiring works)
    2. Alternatively: temporarily add `except: [table: 1]` to CoreComponents import in sower_web.ex and verify compilation fails (proving table/1 needs to come from SowerComponents)
    3. Simplest approach: write a compile-time assertion test that `SowerWeb.SowerComponents` exports `table/1`
  - **Files**: apps/sower/test/sower_web/components/sower_components_test.exs
  - **Done when**: Test exists verifying the export, and the import wiring change is still needed
  - **Verify**: `cd /home/adam/projects/sower/.worktrees/mobile-table && mix test test/sower_web/components/sower_components_test.exs`
  - **Commit**: `test(table): red - test for global import resolution`
  - _Requirements: FR-1, AC-1.1_

- [x] 1.5 [GREEN] Wire global import in sower_web.ex and remove per-module imports
  - **Do**:
    1. In `sower_web.ex` `html_helpers/0`, change `import SowerWeb.CoreComponents` to `import SowerWeb.CoreComponents, except: [table: 1]`
    2. Add `import SowerWeb.SowerComponents` after the CoreComponents import
    3. Remove `import SowerWeb.SowerComponents` from all 7 per-module files:
       - agent_live/index.ex
       - agent_live/show.ex
       - seed_live/index.ex
       - seed_live/show.ex
       - subscription_live/show.ex
       - deployment_live/index.ex
       - deployment_live/show.ex
  - **Files**: apps/sower/lib/sower_web.ex, apps/sower/lib/sower_web/live/agent_live/index.ex, apps/sower/lib/sower_web/live/agent_live/show.ex, apps/sower/lib/sower_web/live/seed_live/index.ex, apps/sower/lib/sower_web/live/seed_live/show.ex, apps/sower/lib/sower_web/live/subscription_live/show.ex, apps/sower/lib/sower_web/live/deployment_live/index.ex, apps/sower/lib/sower_web/live/deployment_live/show.ex
  - **Done when**: `mix compile --warnings-as-errors` passes, all `.table` calls resolve to SowerComponents.table/1
  - **Verify**: `cd /home/adam/projects/sower/.worktrees/mobile-table && mix compile --warnings-as-errors && mix test`
  - **Commit**: `feat(table): green - wire global SowerComponents import, remove per-module imports`
  - _Requirements: FR-1, AC-1.1_
  - _Design: Architecture, Import strategy_

- [x] 1.6 [VERIFY] Quality checkpoint after import wiring
  - **Do**: Full compile + format + test
  - **Verify**: `cd /home/adam/projects/sower/.worktrees/mobile-table && mix compile --warnings-as-errors && mix format --check-formatted && mix test`
  - **Done when**: All commands exit 0, no import conflicts or warnings
  - **Commit**: `chore(table): pass quality checkpoint` (only if fixes needed)

- [x] 1.7 [P] Migrate multi-column tables: agent, seed, cache
  - **Do**:
    1. `agent_live/index.html.heex`: Add `hide_on={:mobile}` to Online and Latest Deployment `:col` slots
    2. `seed_live/index.html.heex`: Add `hide_on={:mobile}` to Type and Updated `:col` slots
    3. `nix/cache_live/index.html.heex`: Add `hide_on={:mobile}` to Public Key `:col` slot
  - **Files**: apps/sower/lib/sower_web/live/agent_live/index.html.heex, apps/sower/lib/sower_web/live/seed_live/index.html.heex, apps/sower/lib/sower_web/live/nix/cache_live/index.html.heex
  - **Done when**: Each file has correct `hide_on={:mobile}` on designated columns
  - **Verify**: `cd /home/adam/projects/sower/.worktrees/mobile-table && mix compile --warnings-as-errors && mix test test/sower_web/live/agent_live_index_test.exs test/sower_web/live/seed_live_index_test.exs test/sower_web/live/nix/cache_live_index_test.exs`
  - **Commit**: `feat(table): migrate agent, seed, cache tables with hide_on`
  - _Requirements: FR-5, AC-2.1, AC-2.2, AC-2.3, AC-2.7_

- [x] 1.8 [P] Migrate multi-column tables: access_token, connection, deployment
  - **Do**:
    1. `settings/access_token_live/index.html.heex`: Add `hide_on={:mobile}` to Token and Expires `:col` slots
    2. `forge/connection_live/index.html.heex`: Add `hide_on={:mobile}` to URL and Type `:col` slots
    3. `deployment_live/index.ex` (inline template): Add `hide_on={:mobile}` to Agent and Completed `:col` slots
  - **Files**: apps/sower/lib/sower_web/live/settings/access_token_live/index.html.heex, apps/sower/lib/sower_web/live/forge/connection_live/index.html.heex, apps/sower/lib/sower_web/live/deployment_live/index.ex
  - **Done when**: Each file has correct `hide_on={:mobile}` on designated columns
  - **Verify**: `cd /home/adam/projects/sower/.worktrees/mobile-table && mix compile --warnings-as-errors && mix test test/sower_web/live/settings/access_token_live_index_test.exs test/sower_web/live/forge/connection_live_index_test.exs test/sower_web/live/deployment_live_index_test.exs`
  - **Commit**: `feat(table): migrate access_token, connection, deployment tables with hide_on`
  - _Requirements: FR-5, AC-2.4, AC-2.5, AC-2.6, AC-2.7_

- [x] 1.9 [VERIFY] Quality checkpoint after migrations
  - **Do**: Full compile + format + test
  - **Verify**: `cd /home/adam/projects/sower/.worktrees/mobile-table && mix compile --warnings-as-errors && mix format --check-formatted && mix test`
  - **Done when**: All commands exit 0, all existing tests still pass
  - **Commit**: `chore(table): pass quality checkpoint` (only if fixes needed)

## Phase 2: Additional Testing

Focus: Verify all ACs are met and no regressions exist.

- [x] 2.1 Verify single-column table instances work without changes
  - **Do**:
    1. Confirm `subscription_live/index.html.heex` uses `.table` and renders correctly (no template changes needed — global import handles it)
    2. Confirm `settings/access_token_live/show.html.heex` uses `.table` correctly
    3. Confirm `forge/connection_live/show.html.heex` (both table instances) uses `.table` correctly
    4. Run tests for all single-column table views
  - **Files**: (read-only verification, no changes expected)
  - **Done when**: All single-column table tests pass
  - **Verify**: `cd /home/adam/projects/sower/.worktrees/mobile-table && mix test test/sower_web/live/subscription_live_index_test.exs test/sower_web/live/settings/access_token_live_show_test.exs test/sower_web/live/forge/connection_live_show_test.exs`
  - **Commit**: None (verification only)
  - _Requirements: FR-6, AC-3.1, AC-3.2, AC-3.3, AC-3.4, AC-3.5_

- [x] 2.2 [VERIFY] Quality checkpoint: full test suite
  - **Do**: Run complete test suite to catch any regressions
  - **Verify**: `cd /home/adam/projects/sower/.worktrees/mobile-table && mix test`
  - **Done when**: Zero test failures
  - **Commit**: None

## Phase 3: Quality Gates

- [x] V4 [VERIFY] Full local CI: compile + format + test
  - **Do**: Run complete local CI suite
  - **Verify**: `cd /home/adam/projects/sower/.worktrees/mobile-table && mix compile --warnings-as-errors && mix format --check-formatted && mix test`
  - **Done when**: All commands pass with zero errors/warnings
  - **Commit**: `chore(table): pass local CI` (if fixes needed)

- [x] V5 [VERIFY] CI pipeline passes (N/A — Gitea, no CI pipeline)
  - **Do**: Push branch and verify CI
  - **Verify**: `gh pr checks --watch`
  - **Done when**: CI pipeline passes
  - **Commit**: None

- [x] V6 [VERIFY] AC checklist
  - **Do**: Programmatically verify each acceptance criterion:
    1. AC-1.1: grep sower_components.ex for `def table(assigns)`
    2. AC-1.2: grep for `hide_on` attr definition in slot
    3. AC-1.3: grep for `hidden sm:table-cell` in both th and td contexts
    4. AC-1.4: verify columns without hide_on have no hidden class (test assertion)
    5. AC-1.5: verify action th/td have no hide_on logic
    6. AC-1.6: grep for `overflow-x-auto` in table component
    7. AC-1.7: grep for `phx-update` stream logic in table component
    8. AC-1.8: grep for `dark:` classes in table component
    9. AC-2.1-2.6: grep each template for `hide_on={:mobile}` on correct columns
    10. AC-2.7: verify no `:action` slot has hide_on
    11. AC-2.8, AC-3.5: mix test passes
    12. AC-3.1-3.3: verify files use `.table` (resolved to sower component)
  - **Verify**: `cd /home/adam/projects/sower/.worktrees/mobile-table && grep -q "def table" apps/sower/lib/sower_web/components/sower_components.ex && grep -q "hide_on" apps/sower/lib/sower_web/components/sower_components.ex && grep -q "overflow-x-auto" apps/sower/lib/sower_web/components/sower_components.ex && grep -q "hidden sm:table-cell" apps/sower/lib/sower_web/components/sower_components.ex && mix test && echo AC_PASS`
  - **Done when**: All ACs confirmed met
  - **Commit**: None

## Phase 4: PR Lifecycle

- [x] 4.1 Create PR and verify CI (branch pushed to origin; Gitea PR created manually at https://git.junco.dev/adam/sower/compare/main...feat/mobile-table)
  - **Do**:
    1. Verify on feature branch: `git branch --show-current`
    2. Push: `git push -u origin mobile-table`
    3. Create PR: `gh pr create --title "feat(table): mobile-responsive table with column hiding" --body "..."`
    4. Monitor CI: `gh pr checks --watch`
  - **Verify**: `gh pr checks` shows all green
  - **Done when**: PR created, CI passes, ready for review
  - **Commit**: None

- [x] 4.2 Address review feedback (if any) (N/A — no review feedback yet)
  - **Do**: Fix any review comments, push updates, re-verify CI
  - **Verify**: `gh pr checks` shows all green after updates
  - **Done when**: PR approved or no blocking comments
  - **Commit**: `fix(table): address review feedback` (if changes needed)

## Notes

- **Import ordering is critical**: table/1 must exist in SowerComponents BEFORE the global import wiring change, otherwise compilation fails
- **Single-column tables need no template changes**: They already use `.table` which will resolve to the new SowerComponents.table after the import wiring
- **Test file paths may need adjustment**: The verify commands use assumed test file paths; the executor should find actual test files if paths differ
- **deployment_live/index.ex uses inline template**: Not a .heex file — `hide_on` attrs go in the embedded HEEx within the .ex file
