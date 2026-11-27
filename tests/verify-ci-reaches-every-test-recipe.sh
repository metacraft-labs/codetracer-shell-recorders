#!/usr/bin/env bash
# Every test recipe in the Justfile must be run by a CI workflow, or say why
# it is not.
#
# A test recipe is one whose name starts with test, verify, e2e or check: the
# names the organisation's `ci-test-audit` CI-coverage audit treats as tests. A recipe is reached when a `run:` step of a
# workflow under .github/workflows calls it through `just` (also behind a
# wrapper, as in `dev-exec just test`), or when a reached recipe calls it
# (`just <recipe>` in its body) or depends on it. A recipe no
# workflow reaches passes only when the comment line directly above it is
# `# ci-test-audit: <reason>`, for example `covered-by test` for an alias of
# recipes `test` runs, or `manual-only (<the hardware CI lacks>)`. That is the
# annotation ci-test-audit reads, so this check and the audit agree.
#
# It exists because `test-dev-shell` sat outside every workflow: a real test
# that CI never ran, with nothing in the repository to notice. Recipes whose
# names are not test names (`cross-test`, run by cross-repo-tests.yml through
# scripts/run-cross-repo-tests.sh) are outside the rule, as they are outside
# ci-test-audit's.
#
# Needs `just`, `jq` and mikefarah's `yq` (nixpkgs `yq-go`), all from the dev
# shell.
#
#   bash tests/verify-ci-reaches-every-test-recipe.sh
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

recipes_json="$(just --dump --dump-format json)"

# name -> callees: dependencies plus every `just <name>` in the body. Body
# fragments are strings or interpolation objects; only the strings can name a
# recipe.
edges="$(jq -r '
  .recipes[] | .name as $n
  | ([.dependencies[].recipe]
     + ([.body[][] | strings] | join("\n")
        | [scan("\\bjust\\s+(?:-\\S+\\s+)*([A-Za-z0-9_-]+)")[0]]))
  | .[] | "\($n) \(.)"' <<<"$recipes_json")"

mapfile -t all_recipes < <(jq -r '.recipes | keys[]' <<<"$recipes_json")

# Every shell command a workflow step runs, one per line. Shell comments are
# dropped as ci-test-audit's strip_comments drops them (a whole `#` line, or
# ` # ...` after a command): a recipe named only in a comment is not reached.
shopt -s nullglob
workflow_files=(.github/workflows/*.yml .github/workflows/*.yaml)
shopt -u nullglob
workflow_runs=""
if ((${#workflow_files[@]})); then
  workflow_runs="$(yq eval-all '.jobs[].steps[].run // ""' "${workflow_files[@]}" |
    sed -E '/^[[:space:]]*#/d; s/[[:space:]]#[[:space:]].*$//')"
fi

declare -A reached=()
queue=()
for recipe in "${all_recipes[@]}"; do
  if grep -Eq "(^|[^[:alnum:]_-])just([[:space:]]+-[^[:space:]]+)*[[:space:]]+${recipe}([^[:alnum:]_-]|\$)" <<<"$workflow_runs"; then
    reached[$recipe]=1
    queue+=("$recipe")
  fi
done
while ((${#queue[@]})); do
  current="${queue[0]}"
  queue=("${queue[@]:1}")
  while read -r caller callee; do
    [ "$caller" = "$current" ] || continue
    [ -n "${reached[$callee]:-}" ] && continue
    reached[$callee]=1
    queue+=("$callee")
  done <<<"$edges"
done

# The `# ci-test-audit: <reason>` line directly above a recipe header.
declare -A declared=()
while IFS=$'\t' read -r recipe reason; do
  declared[$recipe]="$reason"
done < <(awk '
  /^#[[:space:]]*ci-test-audit:/ { note = $0; sub(/^#[[:space:]]*ci-test-audit:[[:space:]]*/, "", note); next }
  /^@?[A-Za-z0-9_-]+[^:=]*:([^=]|$)/ && note != "" {
    name = $0; sub(/^@/, "", name); sub(/[^A-Za-z0-9_-].*/, "", name)
    print name "\t" note
  }
  { note = "" }' Justfile)

unreached=()
for recipe in "${all_recipes[@]}"; do
  [[ "$recipe" =~ ^(test|verify|e2e|check) ]] || continue
  [ -n "${reached[$recipe]:-}" ] && continue
  if [ -n "${declared[$recipe]:-}" ]; then
    echo "declared not scheduled: $recipe (${declared[$recipe]})"
    continue
  fi
  unreached+=("$recipe")
done

if ((${#unreached[@]})); then
  for recipe in "${unreached[@]}"; do
    echo "test recipe no workflow runs: $recipe (call it from .github/workflows or put '# ci-test-audit: <reason>' directly above it)" >&2
  done
  exit 1
fi

echo "verify-ci-reaches-every-test-recipe: passed"
