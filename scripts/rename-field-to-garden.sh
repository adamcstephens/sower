#!/usr/bin/env bash
set -euo pipefail

# Rename "Field" → "Garden" and "field" → "garden" across the codebase.
# Excludes: deps/, _build/, .jj/, priv/repo/migrations/, node_modules/
#
# Usage:
#   ./scripts/rename-field-to-garden.sh          # dry run (show what would change)
#   ./scripts/rename-field-to-garden.sh --apply   # actually do it

DRY_RUN=true
if [[ "${1:-}" == "--apply" ]]; then
  DRY_RUN=false
fi

cd "$(git rev-parse --show-toplevel)"

# --- Phase 1: Content replacements ---

# Files to process (exclude deps, _build, migrations, .jj, node_modules, this script)
mapfile -t FILES < <(
  rg --files \
    --glob '!deps/**' \
    --glob '!_build/**' \
    --glob '!.jj/**' \
    --glob '!node_modules/**' \
    --glob '!**/priv/repo/migrations/**' \
    --glob '!priv/static/**' \
    --glob '!scripts/rename-field-to-garden.sh' \
    --glob '!*.beam' \
    --glob '!*.ez'
)

# Do a broad field→garden replacement, then fix false positives.
# The broad replacement catches everything; false-positive restoration
# handles the typedstruct/ecto `field :atom` macro pattern.
SED_RULES=(
  # Capitalized module/type names
  -e 's/Field/Garden/g'
  # Lowercase everywhere
  -e 's/field/garden/g'
  # Restore typedstruct/ecto macro: `    garden :foo` → `    field :foo`
  -e 's/^\([[:space:]]*\)garden :\([a-z_]\)/\1field :\2/g'
  # Restore Ecto query field() calls: `garden(:foo)` → `field(:foo)`
  -e 's/\bgarden(:/field(:/g'
  # Restore Ecto.Changeset.get_field/2, put_field/3, fetch_field/2
  -e 's/get_garden(changeset/get_field(changeset/g'
  -e 's/put_garden(changeset/put_field(changeset/g'
  -e 's/fetch_garden(changeset/fetch_field(changeset/g'
  # Restore Phoenix.HTML.FormField
  -e 's/FormGarden/FormField/g'
  # Restore Phoenix component `field={...}` attribute (form fields)
  -e 's/garden={@form/field={@form/g'
  -e 's/garden={perm/field={perm/g'
)

echo "=== Phase 1: Content replacements ==="
echo "Files to scan: ${#FILES[@]}"
echo ""

CHANGED_COUNT=0

for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || continue

  if ! diff -q <(cat "$f") <(sed "${SED_RULES[@]}" "$f") >/dev/null 2>&1; then
    CHANGED_COUNT=$((CHANGED_COUNT + 1))
    if $DRY_RUN; then
      echo "--- $f ---"
      diff --color=always -u "$f" <(sed "${SED_RULES[@]}" "$f") || true
      echo ""
    else
      sed -i "${SED_RULES[@]}" "$f"
      echo "  replaced: $f"
    fi
  fi
done

echo ""
echo "Content changes: ${CHANGED_COUNT} files"

# --- Phase 2: File and directory renames ---
# Only rename files/dirs where "field" is OUR domain concept.
# Skip priv/repo/migrations/ entirely (immutable).

echo ""
echo "=== Phase 2: File/directory renames ==="

rename_if_needed() {
  local f="$1"
  local dir base newbase
  dir=$(dirname "$f")
  base=$(basename "$f")
  newbase="${base//field/garden}"
  if [[ "$base" != "$newbase" ]]; then
    if $DRY_RUN; then
      echo "  rename: $f -> $dir/$newbase"
    else
      mv "$f" "$dir/$newbase"
      echo "  renamed: $f -> $dir/$newbase"
    fi
  fi
}

# Rename files (deepest first), excluding migrations
mapfile -t RENAME_FILES < <(
  find apps nix config -path '*/deps' -prune -o \
    -path '*/_build' -prune -o \
    -path '*/priv/repo/migrations' -prune -o \
    -name '*field*' -print 2>/dev/null | sort -r
)

for f in "${RENAME_FILES[@]}"; do
  rename_if_needed "$f"
done

# Top-level files (e.g. .iex-field.exs)
for f in .iex-field*; do
  [[ -e "$f" ]] && rename_if_needed "$f"
done

echo ""
if $DRY_RUN; then
  echo "DRY RUN complete. Run with --apply to execute."
else
  echo "Rename complete. Run 'mix format' and 'mix compile' to verify."
fi
